// 文件: StorageService.swift — JSON 文件持久化服务（Documents/ParrotPlayerData，线程安全，协议见 ARCHITECTURE.md §4）

import Foundation

public protocol StorageServiceProtocol {
    /// 读取 JSON 文件到模型；文件不存在时返回 nil
    func load<T: Codable>(_ type: T.Type, from fileName: String) -> T?
    /// 保存模型到 JSON 文件
    func save<T: Codable>(_ object: T, to fileName: String) throws
    /// 删除文件
    func remove(fileName: String) throws
    /// 容器目录（Documents 或 App Group）
    var containerURL: URL { get }
}

/// JSON 文件存储实现：数据统一存放于 Documents/ParrotPlayerData/ 目录。
/// 内部使用串行 DispatchQueue 保证 load/save/remove 的线程安全。
public final class StorageService: StorageServiceProtocol, @unchecked Sendable {

    /// 数据子目录名（Documents 下）
    public static let dataDirectoryName = "ParrotPlayerData"

    /// JSON 编码器：prettyPrinted + iso8601 日期
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        return encoder
    }()

    /// JSON 解码器：iso8601 日期
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private let queue = DispatchQueue(label: "com.parrot.player.storageservice")

    /// 实际容器目录（Documents/ParrotPlayerData）
    public let containerURL: URL

    /// - Parameter baseURL: 容器根目录；默认使用 App Documents 目录。
    ///   未来切换 App Group 时可传入 group 容器 URL。
    public init(baseURL: URL? = nil) {
        let root: URL
        if let baseURL {
            root = baseURL
        } else {
            root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        }
        containerURL = root.appendingPathComponent(StorageService.dataDirectoryName, isDirectory: true)
    }

    public func load<T: Codable>(_ type: T.Type, from fileName: String) -> T? {
        queue.sync {
            let fileURL = containerURL.appendingPathComponent(fileName)
            // 文件不存在时 contents(atPath:) 返回 nil，符合协议约定
            guard let data = FileManager.default.contents(atPath: fileURL.path) else {
                return nil
            }
            return try? decoder.decode(type, from: data)
        }
    }

    public func save<T: Codable>(_ object: T, to fileName: String) throws {
        try queue.sync {
            // 保存前确保数据目录存在
            try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
            let fileURL = containerURL.appendingPathComponent(fileName)
            let data = try encoder.encode(object)
            try data.write(to: fileURL, options: .atomic)
        }
    }

    public func remove(fileName: String) throws {
        try queue.sync {
            let fileURL = containerURL.appendingPathComponent(fileName)
            // 文件不存在时视为已删除，直接返回
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
