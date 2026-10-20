// 文件: VideoItem.swift — 视频媒体项数据模型（媒体来源类型 + 视频条目，含断点续播字段）

import Foundation

/// 媒体来源类型
public enum VideoSourceKind: String, Codable, CaseIterable, Sendable {
    case local          // App 沙盒/Documents
    case remoteURL      // 远程直链(http/https)
    case networkShare   // SMB/FTP/WebDAV/NFS（预留）
    case cloudDrive     // 网盘（阿里云盘/百度网盘，预留）
    case ted            // 内置 TED 资源（预留）
}

public struct VideoItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var title: String
    public var url: URL                 // 本地 fileURL 或远程 URL
    public var kind: VideoSourceKind
    public var fileSize: Int64?         // 字节
    public var duration: TimeInterval?  // 秒
    public var thumbnailPath: String?   // 本地缓存的封面相对路径
    public var subtitlePath: String?    // 匹配到的外挂字幕本地路径
    public var dateAdded: Date
    public var lastPlayed: Date?
    public var isFavorite: Bool = false
    // 断点续播
    public var resumePosition: TimeInterval = 0

    public init(title: String, url: URL, kind: VideoSourceKind, fileSize: Int64? = nil,
                duration: TimeInterval? = nil, thumbnailPath: String? = nil,
                subtitlePath: String? = nil, dateAdded: Date = Date()) {
        self.title = title; self.url = url; self.kind = kind
        self.fileSize = fileSize; self.duration = duration
        self.thumbnailPath = thumbnailPath; self.subtitlePath = subtitlePath
        self.dateAdded = dateAdded
    }
}
