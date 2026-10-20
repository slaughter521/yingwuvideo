// 文件: HistoryStore.swift — 播放历史/断点续播存储（@MainActor；history.json；最新在前，上限 200 条；协议见 ARCHITECTURE.md §4）

import Combine
import Foundation

public protocol HistoryStoring {
    var records: [PlaybackRecord] { get }
    func record(video: VideoItem, position: TimeInterval, duration: TimeInterval)
    func resumePosition(for videoID: UUID) -> TimeInterval?
    func remove(_ record: PlaybackRecord)
    func clearAll()
}

/// 播放历史存储实现：
/// - 数据持久化于 StorageService 容器目录（Documents/ParrotPlayerData/）下的 history.json
/// - records 按 datePlayed 倒序（最新在前），数量上限 200 条
/// - @MainActor 隔离：所有读写都在主线程完成，避免与 UI 状态竞争
@MainActor
public final class HistoryStore: HistoryStoring {

    /// 历史记录（最新在前；超出 maxRecordCount 时丢弃最旧记录）
    @Published public private(set) var records: [PlaybackRecord] = []

    /// 历史上限条数
    public static let maxRecordCount = 200

    private let storage: StorageServiceProtocol
    private let fileName = "history.json"

    public init(storage: StorageServiceProtocol = StorageService()) {
        self.storage = storage
        // 首次启动或文件损坏时回退为空列表
        let loaded = storage.load([PlaybackRecord].self, from: fileName) ?? []
        // 兜底排序，保证倒序（最新在前）
        self.records = loaded.sorted { $0.datePlayed > $1.datePlayed }
    }

    // MARK: - HistoryStoring

    public func record(video: VideoItem, position: TimeInterval, duration: TimeInterval) {
        let now = Date()
        if let index = records.firstIndex(where: { $0.videoID == video.id }) {
            // 同一视频：更新进度、时长、标题，并移到最前
            records[index].position = position
            records[index].duration = duration
            records[index].datePlayed = now
            records[index].title = video.title
            let updated = records.remove(at: index)
            records.insert(updated, at: 0)
        } else {
            let record = PlaybackRecord(videoID: video.id, title: video.title,
                                        position: position, duration: duration, datePlayed: now)
            records.insert(record, at: 0)
        }
        // 超出上限时丢弃最旧记录
        if records.count > Self.maxRecordCount {
            records = Array(records.prefix(Self.maxRecordCount))
        }
        persist()
    }

    public func resumePosition(for videoID: UUID) -> TimeInterval? {
        records.first { $0.videoID == videoID }?.position
    }

    public func remove(_ record: PlaybackRecord) {
        records.removeAll { $0.id == record.id }
        persist()
    }

    public func clearAll() {
        records = []
        persist()
    }

    // MARK: - 协议外补充方法

    /// 按 datePlayed 倒序返回全部历史记录（供「最近播放」列表使用）
    public func recordList() -> [PlaybackRecord] {
        records
    }

    // MARK: - 私有

    private func persist() {
        // best-effort 持久化，写盘失败不影响内存状态
        try? storage.save(records, to: fileName)
    }
}
