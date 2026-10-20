// 文件: PlaybackModels.swift — 播放列表与播放历史记录模型（含播放进度计算）

import Foundation

/// 播放列表（队列）
public struct Playlist: Identifiable, Codable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var items: [VideoItem]
    public var currentIndex: Int = 0
}

/// 播放历史记录
public struct PlaybackRecord: Identifiable, Codable, Sendable {
    public var id: UUID = UUID()
    public var videoID: UUID
    public var title: String
    public var position: TimeInterval        // 上次播放位置（秒）
    public var duration: TimeInterval
    public var datePlayed: Date
    public var progress: Double {            // 0...1
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }
}
