// 文件: DictionaryService.swift — 词典服务
// 职责：实现 DictionaryServiceProtocol。本地查询走内置离线小词典（LocalDictionary），
//       在线查询走 Free Dictionary API（dictionaryapi.dev），结果写入 NSCache 内存缓存；
//       在线失败时降级到本地，全部失败抛出中文错误描述。
import Foundation

// MARK: - 服务协议（ARCHITECTURE.md §4 逐字定义，禁止修改）

public protocol DictionaryServiceProtocol {
    /// 本地离线释义（内置精简词典 + 缓存）
    func lookup(_ word: String) -> WordDefinition?
    /// 在线查询（有道/Free Dictionary API，失败降级到本地）
    func lookupOnline(_ word: String) async throws -> WordDefinition
}

// MARK: - 词条模型（ARCHITECTURE.md §4 逐字定义，禁止修改）

public struct WordDefinition: Codable, Sendable {
    public var word: String
    public var phonetic: String?
    public var definitions: [String]        // 英文释义
    public var translation: String?         // 中文释义
    public var examples: [String]
    public var source: String               // "local" / "api"

    public init(word: String, phonetic: String? = nil, definitions: [String],
                translation: String? = nil, examples: [String] = [], source: String) {
        self.word = word
        self.phonetic = phonetic
        self.definitions = definitions
        self.translation = translation
        self.examples = examples
        self.source = source
    }
}

// MARK: - 查询错误（中文提示）

public enum DictionaryError: Error, LocalizedError {
    case networkUnavailable
    case wordNotFound(String)
    case invalidResponse
    case decodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .networkUnavailable:
            return "网络连接失败，请检查网络后重试"
        case .wordNotFound(let word):
            return "未找到单词「\(word)」的释义"
        case .invalidResponse:
            return "在线词典返回了无效数据"
        case .decodingFailed(let reason):
            return "词典数据解析失败：\(reason)"
        }
    }
}

// MARK: - 词典服务实现

public final class DictionaryService: DictionaryServiceProtocol {

    /// 在线词典 API（Free Dictionary API）
    public static let apiBaseURL = "https://api.dictionaryapi.dev/api/v2/entries/en/"

    /// 内存缓存（NSCache 线程安全）
    private let cache = NSCache<NSString, WordDefinitionBox>()
    private let cacheLock = NSLock()

    public init() {}

    // MARK: 本地查询

    public func lookup(_ word: String) -> WordDefinition? {
        let key = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }

        // 优先命中缓存（本地/在线结果均缓存）
        if let cached = cachedDefinition(for: key) { return cached.value }

        guard let entry = LocalDictionary.entries(for: key) else { return nil }
        let definition = WordDefinition(
            word: entry.word,
            phonetic: entry.phonetic,
            definitions: entry.definitions,
            translation: entry.translation,
            examples: entry.examples,
            source: "local"
        )
        storeCache(definition, for: key)
        return definition
    }

    // MARK: 在线查询

    public func lookupOnline(_ word: String) async throws -> WordDefinition {
        let key = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { throw DictionaryError.wordNotFound(word) }

        // 缓存命中直接返回（离线时也可用历史查询结果）
        if let cached = cachedDefinition(for: key) { return cached.value }

        guard let url = URL(string: Self.apiBaseURL + key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key) else {
            throw DictionaryError.invalidResponse
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            // 网络失败：降级到本地词典
            if let local = lookup(key) { return local }
            throw DictionaryError.networkUnavailable
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 {
                // 在线未收录：降级本地，本地也没有则报未找到
                if let local = lookup(key) { return local }
                throw DictionaryError.wordNotFound(word)
            }
            guard (200...299).contains(http.statusCode) else {
                if let local = lookup(key) { return local }
                throw DictionaryError.invalidResponse
            }
        }

        let definition: WordDefinition
        do {
            definition = try Self.parseAPIResponse(data: data, word: key)
        } catch let error as DictionaryError {
            if let local = lookup(key) { return local }
            throw error
        } catch {
            if let local = lookup(key) { return local }
            throw DictionaryError.decodingFailed(error.localizedDescription)
        }
        storeCache(definition, for: key)
        return definition
    }

    // MARK: - API 响应解析

    /// 解析 dictionaryapi.dev 响应：
    /// [{ "phonetics": [{"text": "..."}], "meanings": [{"partOfSpeech": "...", "definitions": [{"definition": "...", "example": "..."}]}] }]
    static func parseAPIResponse(data: Data, word: String) throws -> WordDefinition {
        let items: [APIEntry]
        do {
            items = try JSONDecoder().decode([APIEntry].self, from: data)
        } catch {
            throw DictionaryError.decodingFailed(error.localizedDescription)
        }
        guard !items.isEmpty else { throw DictionaryError.wordNotFound(word) }

        var phonetic: String?
        var definitions: [String] = []
        var examples: [String] = []

        for item in items {
            // 音标：取第一个非空 text
            if phonetic == nil {
                phonetic = item.phonetics?.compactMap { $0.text }.first { !$0.isEmpty }
            }
            for meaning in item.meanings ?? [] {
                for def in meaning.definitions ?? [] {
                    let pos = meaning.partOfSpeech ?? ""
                    if !pos.isEmpty {
                        definitions.append("[\(pos)] \(def.definition ?? "")")
                    } else {
                        definitions.append(def.definition ?? "")
                    }
                    if let example = def.example, !example.isEmpty {
                        examples.append(example)
                    }
                }
            }
        }

        guard !definitions.isEmpty else { throw DictionaryError.invalidResponse }
        return WordDefinition(word: word, phonetic: phonetic, definitions: definitions,
                              translation: nil, examples: examples, source: "api")
    }

    // MARK: - 缓存工具

    private func cachedDefinition(for key: String) -> WordDefinitionBox? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache.object(forKey: key as NSString)
    }

    private func storeCache(_ definition: WordDefinition, for key: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache.setObject(WordDefinitionBox(value: definition), forKey: key as NSString)
    }
}

// MARK: - API 响应模型（内部）

/// NSCache 需要引用类型包装
final class WordDefinitionBox {
    let value: WordDefinition
    init(value: WordDefinition) { self.value = value }
}

private struct APIEntry: Decodable {
    var phonetics: [APIPhonetic]?
    var meanings: [APIMeaning]?
}

private struct APIPhonetic: Decodable {
    var text: String?
}

private struct APIMeaning: Decodable {
    var partOfSpeech: String?
    var definitions: [APIDefinition]?
}

private struct APIDefinition: Decodable {
    var definition: String?
    var example: String?
}
