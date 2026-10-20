// 文件: SettingsViewModel.swift — 设置 ViewModel：偏好修改持久化、数据清理、存储统计与学习数据导出（@MainActor，ObservableObject）

import Combine
import Foundation

@MainActor
public final class SettingsViewModel: ObservableObject {

    /// 全局设置存储（只修改 settings 字段并调用 save()）
    public var settingsStore: AppSettingsStore

    /// Toast 回调：由 SettingsView 注入 `{ toastCenter.show($0) }`。
    /// 备选方案：直接注入 ToastCenter 引用；此处选用 closure，使 VM 不依赖 RootView 中的具体类型。
    public var onToast: ((String) -> Void)?

    private let storage: StorageServiceProtocol

    /// 需要清理的学习/历史数据文件（settings.json 保留）
    private let dataFilesToClear = [
        "history.json", "wordbook.json", "favorites.json", "notes.json", "shadowing.json"
    ]

    public init(settingsStore: AppSettingsStore, storage: StorageServiceProtocol = StorageService()) {
        self.settingsStore = settingsStore
        self.storage = storage
    }

    // MARK: - 设置修改（统一：改字段 + save）

    /// 通用设置更新：闭包内修改 AppSettings 字段，随后立即持久化
    public func update(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settingsStore.settings)
        settingsStore.save()
    }

    /// 设置默认倍速（限制 0.2...2.5）
    public func setDefaultSpeed(_ speed: Float) {
        settingsStore.settings.defaultSpeed = min(max(speed, 0.2), 2.5)
        settingsStore.save()
    }

    // MARK: - 数据清理

    /// 清空播放历史/生词本/收藏/笔记/跟读记录 + 缩略图缓存目录（保留 settings.json）
    public func clearAllData() {
        for fileName in dataFilesToClear {
            try? storage.remove(fileName: fileName)
        }
        // 清理缩略图缓存目录（Documents/Thumbnails，与 LibraryService 约定一致）
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let thumbnails = documents.appendingPathComponent(LibraryService.thumbnailsDirectoryName, isDirectory: true)
        if FileManager.default.fileExists(atPath: thumbnails.path) {
            try? FileManager.default.removeItem(at: thumbnails)
        }
        onToast?("已清空播放历史与学习数据")
    }

    // MARK: - 存储统计

    /// 统计 Documents 递归占用空间（ByteCountFormatter 友好输出，如 "1.4 GB"）
    public func storageUsage() async -> String {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let bytes = await Task.detached(priority: .utility) {
            Self.directorySize(at: documents)
        }.value
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// 递归统计目录大小（字节）
    private static func directorySize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            if let allocated = values?.totalFileAllocatedSize {
                total += Int64(allocated)
            } else if let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - 学习数据导出

    /// 汇总生词本/句子收藏/笔记为纯文本（供复制或分享）
    public func exportAllStudyData() -> String {
        // 学习数据文件名与 clearAllData 清理列表一致（由学习模块按同样约定写入）
        let words: [WordEntry] = storage.load([WordEntry].self, from: "wordbook.json") ?? []
        let favorites: [SentenceFavorite] = storage.load([SentenceFavorite].self, from: "favorites.json") ?? []
        let notes: [StudyNote] = storage.load([StudyNote].self, from: "notes.json") ?? []

        var output = "鹦鹉播放器 · 学习数据导出\n"
        output += "导出时间：\(Self.formatDateTime(Date()))\n"

        output += "\n【生词本】共 \(words.count) 词\n"
        for (index, word) in words.enumerated() {
            output += "\(index + 1). \(word.word)"
            if let phonetic = word.phonetic, !phonetic.isEmpty {
                output += "  \(phonetic)"
            }
            output += "\n"
            output += "   释义：\(word.definition)\n"
            if let translation = word.translation, !translation.isEmpty {
                output += "   翻译：\(translation)\n"
            }
            if let sentence = word.sourceSentence, !sentence.isEmpty {
                output += "   原句：\(sentence)\n"
            }
            if let source = word.sourceVideoTitle, !source.isEmpty {
                output += "   来源：《\(source)》\n"
            }
            output += "   复习次数：\(word.reviewCount)｜加入时间：\(Self.formatDateTime(word.dateAdded))\n"
        }

        output += "\n【句子收藏】共 \(favorites.count) 条\n"
        for (index, favorite) in favorites.enumerated() {
            output += "\(index + 1). \(favorite.primaryText)\n"
            if let secondary = favorite.secondaryText, !secondary.isEmpty {
                output += "   \(secondary)\n"
            }
            if let title = favorite.videoTitle, !title.isEmpty {
                output += "   —— 《\(title)》"
                if let time = favorite.videoTime {
                    output += " \(Self.formatTime(time))"
                }
                output += "\n"
            }
            output += "   收藏时间：\(Self.formatDateTime(favorite.dateAdded))\n"
        }

        output += "\n【笔记】共 \(notes.count) 条\n"
        for (index, note) in notes.enumerated() {
            output += "\(index + 1). \(note.content)\n"
            if let sentence = note.sentenceText, !sentence.isEmpty {
                output += "   关联句子：\(sentence)\n"
            }
            if let title = note.videoTitle, !title.isEmpty {
                output += "   视频：《\(title)》"
                if let time = note.videoTime {
                    output += " \(Self.formatTime(time))"
                }
                output += "\n"
            }
            output += "   创建：\(Self.formatDateTime(note.dateCreated))｜修改：\(Self.formatDateTime(note.dateModified))\n"
        }

        return output
    }

    // MARK: - 私有

    private static func formatDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// 视频内时间戳（H:mm:ss / mm:ss）
    private static func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}
