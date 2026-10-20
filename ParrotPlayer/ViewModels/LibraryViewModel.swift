// 文件: LibraryViewModel.swift — 媒体库 ViewModel：扫描/排序/过滤/导入/删除/播放调度（@MainActor，ObservableObject）

import Combine
import Foundation

/// 媒体库排序方式
public enum LibrarySortOrder: String, CaseIterable, Sendable {
    case dateAdded = "添加时间"
    case title = "名称"
    case fileSize = "文件大小"
    case duration = "时长"
}

/// 媒体库展示模式
public enum LibraryViewMode: String, CaseIterable, Sendable {
    case grid = "网格"
    case list = "列表"
}

@MainActor
public final class LibraryViewModel: ObservableObject {

    /// 排序 + 搜索过滤后的展示列表
    @Published public private(set) var videos: [VideoItem] = []
    /// 最近播放记录（最新在前，取前 20 条）
    @Published public private(set) var recentRecords: [PlaybackRecord] = []
    /// 当前播放列表（startPlayback 时设置为当前展示列表）
    @Published public var playlist: [VideoItem] = []
    /// 当前播放下标
    @Published public var currentIndex: Int = 0
    /// 排序方式
    @Published public var sortOrder: LibrarySortOrder = .dateAdded {
        didSet { applySortAndFilter() }
    }
    /// 展示模式（网格/列表）
    @Published public var viewMode: LibraryViewMode = .grid
    /// 搜索关键字（按标题过滤）
    @Published public var searchText: String = "" {
        didSet { applySortAndFilter() }
    }
    /// 最近一次错误提示（中文，供 UI 展示）
    @Published public var errorMessage: String?

    // MARK: 依赖（协议属性，init 注入默认实现）

    public var historyStore: HistoryStoring
    public var libraryService: LibraryServicing

    /// 播放请求回调（契约签名固定，由 LibraryView 注入；与 RootView.handlePlay 同构）
    public var onPlay: ((VideoItem, [VideoItem]) -> Void)?

    /// 全量媒体（未过滤），内部维护
    private var allVideos: [VideoItem] = []

    /// 依赖采用可选参数 + 内部默认实现：避免默认实参在调用方（如 SwiftUI View.init 非隔离上下文）求值
    public init(historyStore: HistoryStoring? = nil, libraryService: LibraryServicing? = nil) {
        self.historyStore = historyStore ?? HistoryStore()
        self.libraryService = libraryService ?? LibraryService()
        refresh()
    }

    // MARK: - 刷新

    /// 扫描本地视频 + 匹配字幕 + 排序过滤 + 异步补缩略图
    public func refresh() {
        do {
            var scanned = try libraryService.scanLocalVideos()
            // 为未匹配字幕的视频匹配同目录字幕
            for index in scanned.indices where scanned[index].subtitlePath == nil {
                if let subtitleURL = libraryService.matchSubtitle(for: scanned[index]) {
                    scanned[index].subtitlePath = subtitleURL.path
                }
            }
            allVideos = scanned
        } catch {
            allVideos = []
            errorMessage = "扫描本地视频失败：\(error.localizedDescription)"
        }
        syncResumePositions()
        applySortAndFilter()
        refreshRecentRecords()
        backfillThumbnails()
    }

    /// 刷新「最近播放」列表（最新 20 条）
    public func refreshRecentRecords() {
        recentRecords = Array(historyStore.records.prefix(20))
    }

    // MARK: - 导入 / 添加 / 删除

    /// 从文件 App / iTunes 共享导入视频（内部异步执行，结果通过 videos / errorMessage 反馈）
    public func importFromDocument(url: URL) {
        Task {
            do {
                var imported = try libraryService.importVideo(from: url)
                if let subtitleURL = libraryService.matchSubtitle(for: imported) {
                    imported.subtitlePath = subtitleURL.path
                }
                allVideos.append(imported)
                applySortAndFilter()
                backfillThumbnails()
            } catch {
                errorMessage = "导入失败：\(error.localizedDescription)"
            }
        }
    }

    /// 解析远程直链并加入媒体库（title 为空时用链接文件名）
    public func addRemoteURL(_ url: URL, title: String? = nil) {
        Task {
            do {
                var item = try await libraryService.probeRemote(url: url)
                if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
                    item.title = title
                }
                allVideos.append(item)
                applySortAndFilter()
            } catch {
                errorMessage = "添加远程链接失败：\(error.localizedDescription)"
            }
        }
    }

    /// 删除媒体（本地文件 + 缩略图缓存 + 对应播放历史）
    public func deleteVideo(_ video: VideoItem) {
        do {
            try libraryService.delete(video)
        } catch {
            errorMessage = "删除失败：\(error.localizedDescription)"
            return
        }
        allVideos.removeAll { $0.id == video.id }
        applySortAndFilter()
        // 清理该视频的播放历史，避免续播位置悬空
        for record in historyStore.records where record.videoID == video.id {
            historyStore.remove(record)
        }
        refreshRecentRecords()
    }

    /// 切换收藏（内存态；收藏列表持久化由学习模块统一管理）
    public func toggleFavorite(_ video: VideoItem) {
        guard let index = allVideos.firstIndex(where: { $0.id == video.id }) else { return }
        allVideos[index].isFavorite.toggle()
        if let displayIndex = videos.firstIndex(where: { $0.id == video.id }) {
            videos[displayIndex].isFavorite = allVideos[index].isFavorite
        }
    }

    // MARK: - 播放调度

    /// 从展示列表指定位置开始播放：设置 playlist/currentIndex 并触发 onPlay 回调
    public func startPlayback(at index: Int) {
        guard videos.indices.contains(index) else { return }
        playlist = videos
        currentIndex = index
        var item = videos[index]
        item.lastPlayed = Date()
        item.resumePosition = historyStore.resumePosition(for: item.id) ?? 0
        // 同步回数据源，保持 UI 一致
        if let sourceIndex = allVideos.firstIndex(where: { $0.id == item.id }) {
            allVideos[sourceIndex].lastPlayed = item.lastPlayed
            allVideos[sourceIndex].resumePosition = item.resumePosition
        }
        videos[index].lastPlayed = item.lastPlayed
        onPlay?(item, playlist)
    }

    /// 继续观看：有播放历史且进度在 2%...95% 之间的视频（按最近播放倒序）
    public var continueWatchingItems: [VideoItem] {
        let recordsByVideoID = Dictionary(uniqueKeysWithValues: historyStore.records.map { ($0.videoID, $0) })
        var paired: [(record: PlaybackRecord, video: VideoItem)] = []
        for video in allVideos {
            guard let record = recordsByVideoID[video.id] else { continue }
            guard record.progress >= 0.02, record.progress <= 0.95 else { continue }
            var item = video
            item.resumePosition = record.position
            paired.append((record, item))
        }
        paired.sort { $0.record.datePlayed > $1.record.datePlayed }
        return paired.map(\.video)
    }

    /// 查询断点续播位置（无历史返回 nil）
    public func resumePosition(for video: VideoItem) -> TimeInterval? {
        historyStore.resumePosition(for: video.id)
    }

    // MARK: - 私有

    /// 将历史中的播放位置同步到媒体项
    private func syncResumePositions() {
        for index in allVideos.indices {
            allVideos[index].resumePosition = historyStore.resumePosition(for: allVideos[index].id) ?? 0
        }
    }

    /// 按排序方式 + 搜索关键字过滤 allVideos → videos
    private func applySortAndFilter() {
        var result = allVideos
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !keyword.isEmpty {
            result = result.filter { $0.title.lowercased().contains(keyword) }
        }
        switch sortOrder {
        case .dateAdded:
            result.sort { $0.dateAdded > $1.dateAdded }
        case .title:
            result.sort { $0.title.localizedStandardCompare($1) == .orderedAscending }
        case .fileSize:
            result.sort { ($0.fileSize ?? -1) > ($1.fileSize ?? -1) }
        case .duration:
            result.sort { ($0.duration ?? -1) > ($1.duration ?? -1) }
        }
        videos = result
    }

    /// 为缺失封面的媒体异步补生成缩略图（并发上限 3：逐批处理，每批最多 3 个）
    private func backfillThumbnails() {
        let pending = allVideos.filter { $0.thumbnailPath == nil }
        guard !pending.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self, pending, libraryService] in
            for batch in LibraryViewModel.batches(pending, size: 3) {
                // 每批最多 3 个并发抓帧任务
                let results = await withTaskGroup(of: (UUID, String?).self) { group in
                    for video in batch {
                        group.addTask {
                            let path = await libraryService.generateThumbnailIfAvailable(for: video)
                            return (video.id, path)
                        }
                    }
                    var collected: [(UUID, String?)] = []
                    for await result in group {
                        collected.append(result)
                    }
                    return collected
                }
                // 回主线程更新封面路径
                for (videoID, path) in results {
                    guard let path else { continue }
                    await MainActor.run {
                        self?.updateThumbnail(videoID: videoID, path: path)
                    }
                }
            }
        }
    }

    /// 数组分块（私有静态方法，避免与他人扩展重名）
    private static func batches<T>(_ array: [T], size: Int) -> [[T]] {
        guard size > 0 else { return [array] }
        var result: [[T]] = []
        var start = 0
        while start < array.count {
            let end = Swift.min(start + size, array.count)
            result.append(Array(array[start..<end]))
            start = end
        }
        return result
    }

    /// 主线程更新缩略图路径（同步 allVideos 与展示列表）
    private func updateThumbnail(videoID: UUID, path: String) {
        if let index = allVideos.firstIndex(where: { $0.id == videoID }) {
            allVideos[index].thumbnailPath = path
        }
        if let index = videos.firstIndex(where: { $0.id == videoID }) {
            videos[index].thumbnailPath = path
        }
    }
}
