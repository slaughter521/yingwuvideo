// 文件: StudyViewModel.swift — 学习模块 ViewModel
// 职责：统一管理生词本、句子收藏、学习笔记、跟读记录与词汇分析状态；
//       数据通过 StorageServiceProtocol 以 JSON 文件持久化（wordbook.json / favorites.json /
//       notes.json / shadowing.json），任何变更即时落盘。词汇分析通过 VocabularyAnalyzing 协议注入，
//       分词与停用词复用 VocabularyAnalyzer 的实现，保证与词汇分析口径一致。

import Foundation
import Combine

// MARK: - 学习模块错误

/// 学习模块错误（中文提示）
public enum StudyError: Error, LocalizedError {
    /// 未注入词汇分析器
    case analyzerNotConfigured

    public var errorDescription: String? {
        switch self {
        case .analyzerNotConfigured:
            return "词汇分析器未配置，无法进行词汇分析"
        }
    }
}

// MARK: - ViewModel

@MainActor
public final class StudyViewModel: ObservableObject {

    // MARK: 持久化文件名

    private let wordBookFileName = "wordbook.json"
    private let favoritesFileName = "favorites.json"
    private let notesFileName = "notes.json"
    private let shadowingFileName = "shadowing.json"

    // MARK: 发布状态

    /// 生词本（最新添加在前）
    @Published public private(set) var wordBook: [WordEntry] = []
    /// 句子收藏（最新收藏在前）
    @Published public private(set) var sentenceFavorites: [SentenceFavorite] = []
    /// 学习笔记（最新创建在前）
    @Published public private(set) var notes: [StudyNote] = []
    /// 跟读评分记录（最新在前）
    @Published public private(set) var shadowingRecords: [ShadowingRecord] = []
    /// 最近一次词汇分析报告（nil 表示尚未分析）
    @Published public private(set) var vocabularyReport: VocabularyReport?
    /// 是否正在词汇分析中（UI 可显示加载态）
    @Published public private(set) var isAnalyzing: Bool = false
    /// 错误提示（中文）。写入后持续保留，直到被下一次操作覆盖或由 UI 手动清除
    @Published public var errorMessage: String?

    // MARK: 上下文（由播放页/学习页注入）

    /// 当前播放视频标题；学习操作未显式指定来源视频时作为回退值
    public var currentVideoTitle: String?
    /// 点击句子时的播放回调，参数为句子时间点（秒）；由播放页注入实现
    public var onPlaySentence: ((TimeInterval) -> Void)?

    // MARK: 词汇分析器

    /// 词汇分析器（需外部注入，例如 `viewModel.analyzer = VocabularyAnalyzer()`）；
    /// 未注入时调用 analyzeSubtitle 会走错误分支
    public var analyzer: VocabularyAnalyzing?

    // MARK: 私有状态

    private let storage: StorageServiceProtocol
    /// 内置词库是否已尝试加载（避免每次分析重复读取 Bundle）
    private var didLoadBuiltinDictionaries = false

    // MARK: 初始化与持久化

    /// 创建学习 ViewModel 并加载已持久化的数据
    /// - Parameter storage: 存储服务，默认 StorageService()（Documents/ParrotPlayerData 下的 JSON 文件）
    public init(storage: StorageServiceProtocol = StorageService()) {
        self.storage = storage
        loadAll()
    }

    /// 重新从磁盘载入学习数据（播放页写入生词/收藏后，学习页出现时调用即可保持同步）
    public func reload() {
        loadAll()
    }

    /// 从 JSON 文件加载全部学习数据（文件不存在时对应集合保持为空）
    private func loadAll() {
        if let words: [WordEntry] = storage.load([WordEntry].self, from: wordBookFileName) {
            wordBook = words
        }
        if let favorites: [SentenceFavorite] = storage.load([SentenceFavorite].self, from: favoritesFileName) {
            sentenceFavorites = favorites
        }
        if let loadedNotes: [StudyNote] = storage.load([StudyNote].self, from: notesFileName) {
            notes = loadedNotes
        }
        if let records: [ShadowingRecord] = storage.load([ShadowingRecord].self, from: shadowingFileName) {
            shadowingRecords = records
        }
    }

    /// 通用落盘：保存失败时写入中文 errorMessage，不中断业务流程
    private func persist<T: Codable>(_ object: T, to fileName: String) {
        do {
            try storage.save(object, to: fileName)
        } catch {
            errorMessage = "学习数据保存失败（\(fileName)）：\(error.localizedDescription)"
        }
    }

    // MARK: 生词本

    /// 添加生词；若同名单词（忽略大小写）已存在，则合并来源信息（补充来源视频标题、
    /// 追加不同的来源句），不重复创建条目；已有释义/音标/复习次数保持不动
    public func addWord(_ entry: WordEntry) {
        let key = entry.word.lowercased()
        if let index = wordBook.firstIndex(where: { $0.word.lowercased() == key }) {
            var existing = wordBook[index]
            // 补充缺失的来源视频标题
            if existing.sourceVideoTitle?.isEmpty != false {
                existing.sourceVideoTitle = entry.sourceVideoTitle
            }
            // 合并来源句：内容不同且未被包含时才追加，避免重复
            if let newSentence = entry.sourceSentence, !newSentence.isEmpty {
                if let oldSentence = existing.sourceSentence, !oldSentence.isEmpty {
                    if oldSentence != newSentence, !oldSentence.contains(newSentence) {
                        existing.sourceSentence = oldSentence + " / " + newSentence
                    }
                } else {
                    existing.sourceSentence = newSentence
                }
            }
            wordBook[index] = existing
        } else {
            wordBook.insert(entry, at: 0)
        }
        persist(wordBook, to: wordBookFileName)
    }

    /// 删除生词（按 id 匹配）
    public func removeWord(_ entry: WordEntry) {
        wordBook.removeAll { $0.id == entry.id }
        persist(wordBook, to: wordBookFileName)
    }

    /// 判断单词是否已在生词本中（忽略大小写）
    public func isInWordBook(word: String) -> Bool {
        let key = word.lowercased()
        return wordBook.contains { $0.word.lowercased() == key }
    }

    /// 批量提取句子中的生词加入生词本：分词与停用词过滤复用 VocabularyAnalyzer 的实现
    /// （与词汇报告口径一致），批内重复与已在生词本中的单词自动跳过。
    /// 释义暂以「待补充」占位，来源句写入整句，便于后续在生词本中完善。
    /// - Parameters:
    ///   - sentence: 来源句子
    ///   - videoTitle: 来源视频标题；传 nil 时回退使用 currentVideoTitle
    public func addWordsFromSentence(_ sentence: String, videoTitle: String? = nil) {
        let sourceTitle = videoTitle ?? currentVideoTitle
        var addedCount = 0
        for token in VocabularyAnalyzer.tokenize(sentence) {
            if VocabularyAnalyzer.stopWords.contains(token) { continue }  // 去停用词
            if token.count < 2 { continue }                               // 去单字母碎片
            if isInWordBook(word: token) { continue }                     // 去重（含本批已加入）
            let entry = WordEntry(word: token,
                                  phonetic: nil,
                                  definition: "待补充",
                                  translation: nil,
                                  sourceVideoTitle: sourceTitle,
                                  sourceSentence: sentence,
                                  dateAdded: Date())
            wordBook.insert(entry, at: 0)
            addedCount += 1
        }
        if addedCount > 0 {
            persist(wordBook, to: wordBookFileName)
        }
    }

    // MARK: 句子收藏

    /// 收藏句子；同一视频下的相同句子不重复收藏
    public func addFavorite(_ favorite: SentenceFavorite) {
        let duplicated = sentenceFavorites.contains {
            $0.primaryText == favorite.primaryText && $0.videoTitle == favorite.videoTitle
        }
        guard !duplicated else { return }
        sentenceFavorites.insert(favorite, at: 0)
        persist(sentenceFavorites, to: favoritesFileName)
    }

    /// 取消收藏（按 id 匹配）
    public func removeFavorite(_ favorite: SentenceFavorite) {
        sentenceFavorites.removeAll { $0.id == favorite.id }
        persist(sentenceFavorites, to: favoritesFileName)
    }

    // MARK: 学习笔记

    /// 新建笔记（插入到最前）
    public func addNote(content: String, videoTitle: String?, videoTime: TimeInterval?, sentenceText: String?) {
        let now = Date()
        let note = StudyNote(content: content,
                             videoTitle: videoTitle,
                             videoTime: videoTime,
                             sentenceText: sentenceText,
                             dateCreated: now,
                             dateModified: now)
        notes.insert(note, at: 0)
        persist(notes, to: notesFileName)
    }

    /// 更新笔记（自动刷新 dateModified；id 不存在时忽略）
    public func updateNote(_ note: StudyNote) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        var updated = note
        updated.dateModified = Date()
        notes[index] = updated
        persist(notes, to: notesFileName)
    }

    /// 删除笔记（按 id 匹配）
    public func deleteNote(_ note: StudyNote) {
        notes.removeAll { $0.id == note.id }
        persist(notes, to: notesFileName)
    }

    // MARK: 跟读记录

    /// 新增跟读评分记录（插入到最前）。audioPath 建议存录音文件绝对路径
    public func addShadowingRecord(_ record: ShadowingRecord) {
        shadowingRecords.insert(record, at: 0)
        persist(shadowingRecords, to: shadowingFileName)
    }

    /// 清空全部跟读记录，并尽力删除各记录引用的录音文件
    public func clearShadowingRecords() {
        for record in shadowingRecords {
            if let path = record.audioPath {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        shadowingRecords.removeAll()
        persist(shadowingRecords, to: shadowingFileName)
    }

    // MARK: 词汇分析

    /// 分析整条字幕轨的词汇分布（需提前注入 analyzer）。
    /// 流程：首次分析触发内置词库加载 → 调用协议 analyze → 结果写入 vocabularyReport；
    /// 分析期间 isAnalyzing 为 true；失败时写入中文 errorMessage 并经 completion 回传错误。
    /// - Parameters:
    ///   - track: 字幕轨（分析 primaryText）
    ///   - completion: 完成回调（主线程），成功携带 VocabularyReport，失败携带 Error
    public func analyzeSubtitle(_ track: SubtitleTrack,
                                completion: ((Result<VocabularyReport, Error>) -> Void)? = nil) {
        // 防止重复触发（上一次分析未结束时忽略新请求）
        guard !isAnalyzing else { return }

        guard let analyzer else {
            let error = StudyError.analyzerNotConfigured
            errorMessage = error.errorDescription
            completion?(.failure(error))
            return
        }

        isAnalyzing = true
        Task {
            // Task 闭包继承 @MainActor 上下文，状态更新与回调均发生在主线程
            defer { self.isAnalyzing = false }

            // 首次分析前显式加载词库；加载失败则中止，避免静默降级为「未分级」
            if !self.didLoadBuiltinDictionaries {
                do {
                    try analyzer.loadBuiltinDictionaries()
                    self.didLoadBuiltinDictionaries = true
                } catch {
                    self.errorMessage = "内置词库加载失败：\(error.localizedDescription)"
                    completion?(.failure(error))
                    return
                }
            }

            var report = analyzer.analyze(track)
            // 分析器不感知当前视频，标题为空时回填，便于报告展示
            if report.videoTitle == nil {
                report.videoTitle = self.currentVideoTitle
            }
            self.vocabularyReport = report
            completion?(.success(report))
        }
    }

    // MARK: 统计

    /// 今日新增生词数（按 dateAdded 是否属于今天统计）
    public var todayCount: Int {
        let calendar = Calendar.current
        return wordBook.filter { calendar.isDateInToday($0.dateAdded) }.count
    }

    /// 生词本按来源视频分组统计（数量降序，同数按标题升序）；
    /// 未记录来源视频的条目归入「未知来源」
    public var wordBookStats: [(videoTitle: String, count: Int)] {
        var counts: [String: Int] = [:]
        for entry in wordBook {
            let title: String
            if let source = entry.sourceVideoTitle, !source.isEmpty {
                title = source
            } else {
                title = "未知来源"
            }
            counts[title, default: 0] += 1
        }
        return counts
            .map { (videoTitle: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count || ($0.count == $1.count && $0.videoTitle < $1.videoTitle) }
    }

    // MARK: 导出

    /// 导出句子收藏为纯文本：标题 + 导出信息 + 每条（序号. 句子 / 译文 / 视频 / 时间）
    public func exportFavoritesToText() -> String {
        var lines: [String] = [
            "鹦鹉播放器收藏句子导出",
            "导出时间：\(Self.exportDateFormatter.string(from: Date()))",
            "共 \(sentenceFavorites.count) 条",
            ""
        ]
        if sentenceFavorites.isEmpty {
            lines.append("（暂无收藏）")
        }
        for (index, favorite) in sentenceFavorites.enumerated() {
            lines.append("\(index + 1). \(favorite.primaryText)")
            if let secondary = favorite.secondaryText, !secondary.isEmpty {
                lines.append("   译文：\(secondary)")
            }
            if let title = favorite.videoTitle, !title.isEmpty {
                lines.append("   视频：\(title)")
            }
            if let time = favorite.videoTime {
                lines.append("   时间：\(Self.formatTimestamp(time))")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// 导出生词本为纯文本：标题 + 导出信息 + 每条（序号. 单词 / 释义 / 来源视频 / 原句）
    public func exportWordBookToText() -> String {
        var lines: [String] = [
            "鹦鹉播放器生词本导出",
            "导出时间：\(Self.exportDateFormatter.string(from: Date()))",
            "共 \(wordBook.count) 个单词",
            ""
        ]
        if wordBook.isEmpty {
            lines.append("（暂无生词）")
        }
        for (index, entry) in wordBook.enumerated() {
            lines.append("\(index + 1). \(entry.word)")
            if let translation = entry.translation, !translation.isEmpty {
                lines.append("   释义：\(entry.definition)（\(translation)）")
            } else if !entry.definition.isEmpty {
                lines.append("   释义：\(entry.definition)")
            }
            if let title = entry.sourceVideoTitle, !title.isEmpty {
                lines.append("   来源视频：\(title)")
            }
            if let sentence = entry.sourceSentence, !sentence.isEmpty {
                lines.append("   原句：\(sentence)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 私有工具

    /// 导出用日期格式（固定区域设置，避免随系统语言漂移）
    private static let exportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// 秒数格式化为 H:MM:SS / MM:SS（负数与非法值归零）
    private static func formatTimestamp(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "00:00" }
        let total = Int(interval.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
