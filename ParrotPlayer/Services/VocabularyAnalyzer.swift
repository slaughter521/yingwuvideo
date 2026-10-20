// 文件: VocabularyAnalyzer.swift — 词汇分析服务
// 职责：实现 VocabularyAnalyzing 协议。从 Bundle 加载内置分级词库（四级/六级/考研/雅思），
//       对字幕轨主语言文本做分词、停用词过滤与简易词形还原，按优先级分级统计，
//       输出 VocabularyReport。分析过程不抛异常、不崩溃，词库缺失时降级为未分级。
import Foundation

// MARK: - 服务协议（ARCHITECTURE.md §4 逐字定义，禁止修改）

public protocol VocabularyAnalyzing {
    /// 分析整条字幕轨的词汇，返回分级统计
    func analyze(_ track: SubtitleTrack) -> VocabularyReport
    /// 查询单个单词的等级
    func level(of word: String) -> (level: VocabularyLevel, lemma: String)
    /// 内置词库加载（cet4/cet6/kaoyan/…），从 Bundle 的 txt 读取
    func loadBuiltinDictionaries() throws
}

// MARK: - 分析错误（中文提示）

public enum VocabularyError: Error, LocalizedError {
    case dictionaryNotLoaded
    case analysisFailed(String)

    public var errorDescription: String? {
        switch self {
        case .dictionaryNotLoaded:
            return "内置词库未加载，请检查应用资源文件是否完整"
        case .analysisFailed(let reason):
            return "词汇分析失败：\(reason)"
        }
    }
}

// MARK: - 分析器实现

public final class VocabularyAnalyzer: VocabularyAnalyzing {

    // MARK: 常量配置

    /// 分级优先级：命中多个词库时取最高（最基础）级别
    static let levelPriority: [VocabularyLevel] = [.cet4, .cet6, .kaoyan, .ielts]

    /// 词库资源文件名（Resources/Vocabulary/ 下，每行一个小写单词）
    static let dictionaryFiles: [(level: VocabularyLevel, name: String)] = [
        (.cet4, "cet4_words"),
        (.cet6, "cet6_words"),
        (.kaoyan, "kaoyan_words"),
        (.ielts, "ielts_words")
    ]

    /// 常见功能词/停用词表（约 150 个，全部小写）
    static let stopWords: Set<String> = [
        // 冠词、介词、连词、代词、助动词
        "the", "a", "an", "and", "or", "but", "if", "so", "as", "at", "by", "of", "to", "in", "on",
        "with", "for", "from", "up", "down", "out", "about", "into", "over", "after", "before",
        "above", "below", "under", "near", "beside", "behind", "between", "among", "across",
        "through", "around", "against", "along", "upon", "within", "without", "toward", "towards",
        "during", "while", "since", "until", "unless", "although", "though", "because", "per", "via",
        // be 动词与助动词
        "is", "are", "am", "was", "were", "been", "being", "be", "do", "does", "did", "have", "has",
        "had", "will", "would", "shall", "should", "can", "could", "may", "might", "must", "ought",
        "need", "dare",
        // 人称代词与物主代词
        "i", "me", "my", "mine", "you", "your", "yours", "he", "him", "his", "she", "her", "hers",
        "it", "its", "we", "us", "our", "ours", "they", "them", "their", "theirs",
        // 指示词与疑问词
        "this", "that", "these", "those", "such", "same", "there", "here", "what", "which", "who",
        "whom", "whose", "when", "where", "why", "how", "whatever", "whoever", "however", "whenever",
        "wherever",
        // 常见副词/情态修饰
        "not", "no", "yes", "too", "very", "just", "also", "more", "most", "much", "many", "few",
        "less", "least", "only", "own", "both", "each", "all", "any", "some", "other", "another",
        "than", "then", "now", "soon", "once", "again", "still", "yet", "ever", "never", "always",
        "often", "sometimes", "maybe", "perhaps", "almost", "enough", "rather", "quite",
        // 情态缩写与 be/助动词缩写
        "ain't", "can't", "cannot", "couldn't", "didn't", "doesn't", "don't", "hadn't", "hasn't",
        "haven't", "isn't", "mightn't", "mustn't", "needn't", "shan't", "shouldn't", "wasn't",
        "weren't", "won't", "wouldn't", "i'm", "i've", "i'll", "i'd", "you're", "you've", "you'll",
        "you'd", "he's", "she's", "it's", "we're", "we've", "we'll", "we'd", "they're", "they've",
        "they'll", "they'd", "that's", "there's", "here's", "what's", "who's", "let's", "o'clock",
        // 高频单字母缩写残留
        "s", "o", "t", "d", "ll", "m", "re", "ve", "y"
    ]

    /// 未命中词库时的"生僻词"长度启发阈值
    static let rareLengthThreshold = 9

    // MARK: 状态

    private let lock = NSLock()
    private var dictionaries: [VocabularyLevel: Set<String>] = [:]
    private var isLoaded = false

    public init() {}

    // MARK: 词库加载

    public func loadBuiltinDictionaries() throws {
        lock.lock()
        defer { lock.unlock() }

        var loaded: [VocabularyLevel: Set<String>] = [:]
        var anyLoaded = false
        for entry in Self.dictionaryFiles {
            if let set = Self.loadWordSet(fileName: entry.name) {
                loaded[entry.level] = set
                anyLoaded = true
            }
        }
        guard anyLoaded else { throw VocabularyError.dictionaryNotLoaded }
        dictionaries = loaded
        isLoaded = true
    }

    /// 从 Bundle 读取单个词库文件（Resources/Vocabulary/ 下优先）
    static func loadWordSet(fileName: String) -> Set<String>? {
        let url = Bundle.main.url(forResource: fileName, withExtension: "txt", subdirectory: "Vocabulary")
            ?? Bundle.main.url(forResource: fileName, withExtension: "txt")
        guard let url = url,
              let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var set = Set<String>()
        for line in content.split(separator: "\n") {
            let word = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !word.isEmpty { set.insert(word) }
        }
        return set.isEmpty ? nil : set
    }

    /// 未加载时尝试懒加载一次（线程安全，失败静默降级）
    private func ensureLoaded() {
        let loaded: Bool
        lock.lock()
        loaded = isLoaded
        lock.unlock()
        if !loaded { try? loadBuiltinDictionaries() }
    }

    // MARK: 单词定级

    public func level(of word: String) -> (level: VocabularyLevel, lemma: String) {
        let token = Self.normalizeToken(word)
        guard !token.isEmpty else { return (.unknown, token) }

        ensureLoaded()
        lock.lock()
        let dicts = dictionaries
        lock.unlock()
        guard !dicts.isEmpty else { return (.unknown, token) }

        // 按级别优先、候选其次逐级匹配词库
        let candidates = Self.lemmaCandidates(token)
        for level in Self.levelPriority {
            guard let set = dicts[level] else { continue }
            for candidate in candidates where set.contains(candidate) {
                return (level, candidate)
            }
        }
        // 未命中词库：长词按生僻词启发，其余未分级
        let lemma = candidates.count > 1 ? candidates[1] : token
        return (token.count >= Self.rareLengthThreshold ? .rare : .unknown, lemma)
    }

    // MARK: 字幕轨分析

    public func analyze(_ track: SubtitleTrack) -> VocabularyReport {
        ensureLoaded()

        // lemma -> (出现次数, 等级, 所在字幕索引集合)
        var occurrences: [String: (count: Int, level: VocabularyLevel, cueIndices: Set<Int>)] = [:]

        for (cueIndex, cue) in track.cues.enumerated() {
            for token in Self.tokenize(cue.primaryText) {
                if Self.stopWords.contains(token) { continue }
                if token.count < 2 { continue }   // 过滤单字母碎片
                let (level, lemma) = level(of: token)
                occurrences[lemma, default: (0, level, [])].count += 1
                occurrences[lemma, default: (0, level, [])].cueIndices.insert(cueIndex)
            }
        }

        let details: [WordOccurrence] = occurrences.map { lemma, info in
            WordOccurrence(word: lemma, level: info.level,
                           count: info.count, cueIndices: info.cueIndices.sorted())
        }
        .sorted { $0.count > $1.count || ($0.count == $1.count && $0.word < $1.word) }

        var levelCounts: [VocabularyLevel: Int] = [:]
        for level in VocabularyLevel.allCases { levelCounts[level] = 0 }
        for detail in details { levelCounts[detail.level, default: 0] += 1 }

        return VocabularyReport(videoTitle: nil,
                                totalWords: details.count,
                                levelCounts: levelCounts,
                                wordDetails: details)
    }

    // MARK: - 分词与规整

    /// 归一化单个外部输入单词（小写、统一撇号、去首尾撇号）
    static func normalizeToken(_ word: String) -> String {
        var t = word.lowercased().replacingOccurrences(of: "’", with: "'")
        while t.hasPrefix("'") { t.removeFirst() }
        while t.hasSuffix("'") { t.removeLast() }
        return t
    }

    /// 分词：仅保留 ASCII 字母与撇号（' ’ ` ´ 归一为 '），其余字符均作分隔。
    /// 中文/日文等非拉丁字符自然成为分隔符，不会粘连整句。
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let isAsciiLetter = (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
            let isApostrophe = v == 0x27 || v == 0x2019 || v == 0x0060 || v == 0x00B4
            if isAsciiLetter {
                current.unicodeScalars.append(scalar)
            } else if isApostrophe && !current.isEmpty {
                current.append("'")   // ' ’ ` ´ 统一为 ASCII 撇号
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens.map { normalizeToken($0) }.filter { !$0.isEmpty }
    }

    // MARK: - 简易词形还原

    /// 生成还原候选（原词优先，随后去 -s/-es/-ies/-ed/-ing/-ly 及双写辅音还原）。
    /// 仅作为"匹配词库的尝试"，命中任一候选即采用该候选为词元。
    static func lemmaCandidates(_ token: String) -> [String] {
        var candidates: [String] = [token]

        // 名词复数：studies→study；boxes→box；cats→cat
        if token.hasSuffix("ies"), token.count > 4 {
            candidates.append(String(token.dropLast(3)) + "y")
        }
        if token.hasSuffix("es"), token.count > 3 {
            candidates.append(String(token.dropLast(2)))
        }
        if token.hasSuffix("s"), !token.hasSuffix("ss"), token.count > 2 {
            candidates.append(String(token.dropLast(1)))
        }

        // 过去式/过去分词：studied→study；used→use；stopped→stop
        if token.hasSuffix("ied"), token.count > 4 {
            candidates.append(String(token.dropLast(3)) + "y")
        }
        if token.hasSuffix("ed"), token.count > 3 {
            let base = String(token.dropLast(2))
            candidates.append(base)
            if base.count >= 2, base.last == base.dropLast(1).last {
                candidates.append(String(base.dropLast(1)))   // 双写辅音还原
            }
            candidates.append(base + "e")                      // 辅音+e 还原（used→use）
        }

        // 现在分词/动名词：making→make；running→run
        if token.hasSuffix("ing"), token.count > 5 {
            let base = String(token.dropLast(3))
            candidates.append(base)
            candidates.append(base + "e")                      // 补 e 还原（making→make）
            if base.count >= 2, base.last == base.dropLast(1).last {
                candidates.append(String(base.dropLast(1)))   // 双写辅音还原
            }
        }

        // 副词 -ly
        if token.hasSuffix("ly"), token.count > 3 {
            candidates.append(String(token.dropLast(2)))
        }

        // 去重且保持顺序
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }
}
