// 文件: PosterWallView.swift — 媒体库海报墙：自适应网格海报卡片 + 异步封面加载 + 收藏/导出/删除上下文菜单

import SwiftUI
import UIKit

/// 海报墙：以网格形式展示媒体库条目
/// - 点击卡片：播放（携带当前展示列表作为播放列表）
/// - 长按卡片：上下文菜单（播放 / 收藏 / 导出音频 / 删除）
public struct PosterWallView: View {

    /// 展示的媒体列表（已排序/过滤）
    public let videos: [VideoItem]
    /// 播放回调（视频项 + 播放列表）
    public let onPlay: (VideoItem, [VideoItem]) -> Void
    /// 收藏/取消收藏回调
    public let onToggleFavorite: (VideoItem) -> Void
    /// 删除回调
    public let onDelete: (VideoItem) -> Void
    /// 导出音频回调
    public let onExportAudio: (VideoItem) -> Void

    /// 自适应列：最小宽度 160，间距 12
    private let columns: [GridItem] = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    public init(videos: [VideoItem],
                onPlay: @escaping (VideoItem, [VideoItem]) -> Void,
                onToggleFavorite: @escaping (VideoItem) -> Void,
                onDelete: @escaping (VideoItem) -> Void,
                onExportAudio: @escaping (VideoItem) -> Void) {
        self.videos = videos
        self.onPlay = onPlay
        self.onToggleFavorite = onToggleFavorite
        self.onDelete = onDelete
        self.onExportAudio = onExportAudio
    }

    public var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(videos) { video in
                    PosterCard(video: video,
                               playlist: videos,
                               onPlay: onPlay,
                               onToggleFavorite: onToggleFavorite,
                               onDelete: onDelete,
                               onExportAudio: onExportAudio)
                }
            }
            .padding(12)
        }
        .background(Color.black)
    }
}

// MARK: - 单个海报卡片

/// 海报卡片：封面（16:9 圆角 12）+ 格式胶囊 + 收藏心 + 标题 + 信息行 + 观看进度
private struct PosterCard: View {

    let video: VideoItem
    let playlist: [VideoItem]
    let onPlay: (VideoItem, [VideoItem]) -> Void
    let onToggleFavorite: (VideoItem) -> Void
    let onDelete: (VideoItem) -> Void
    let onExportAudio: (VideoItem) -> Void

    /// 异步加载的封面图（nil 时显示渐变占位）
    @State private var thumbnail: UIImage?

    /// 缩略图路径解析器（相对路径 → 完整 fileURL）
    private let libraryService = LibraryService()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // 主体按钮：点击播放，按压时整体轻微缩放
            Button {
                onPlay(video, playlist)
            } label: {
                cardContent
            }
            .buttonStyle(PressScaleButtonStyle())

            // 收藏心（与播放按钮平级，避免嵌套按钮抢事件）
            favoriteButton
                .padding(12)
        }
        .contextMenu {
            Button {
                onPlay(video, playlist)
            } label: {
                Label("播放", systemImage: "play.fill")
            }
            Button {
                onToggleFavorite(video)
            } label: {
                Label(video.isFavorite ? "取消收藏" : "收藏",
                      systemImage: video.isFavorite ? "heart.slash" : "heart")
            }
            Button {
                onExportAudio(video)
            } label: {
                Label("导出音频", systemImage: "waveform")
            }
            Button(role: .destructive) {
                onDelete(video)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    // MARK: 卡片内容

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            coverLayer
            titleView
            infoView
            progressView
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.10))
        )
    }

    /// 封面层：渐变占位 + 异步本地封面 + 中央播放图标
    private var coverLayer: some View {
        ZStack {
            placeholderGradient
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            }
            Image(systemName: "play.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 1)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topLeading) { formatBadge.padding(8) }
        .task(id: video.thumbnailPath) {
            await loadThumbnail()
        }
    }

    /// 标题：最多 2 行
    private var titleView: some View {
        Text(video.title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 信息行：时长 · 大小
    private var infoView: some View {
        HStack(spacing: 4) {
            Text(Self.durationText(video.duration))
            Text("·")
            Text(Self.sizeText(video.fileSize))
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.55))
        .lineLimit(1)
    }

    /// 观看进度：细条 + 「已看 x%」
    @ViewBuilder
    private var progressView: some View {
        if progress > 0.005 {
            VStack(alignment: .leading, spacing: 3) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.15))
                        Capsule()
                            .fill(Self.parrotYellow)
                            .frame(width: max(proxy.size.width * progress, 2))
                    }
                }
                .frame(height: 3)
                Text("已看 \(Int(round(progress * 100)))%")
                    .font(.caption2)
                    .foregroundStyle(Self.parrotYellow.opacity(0.9))
            }
        }
    }

    /// 观看进度 0...1（无时长时按未观看处理）
    private var progress: Double {
        guard let duration = video.duration, duration > 0 else { return 0 }
        return min(max(video.resumePosition / duration, 0), 1)
    }

    // MARK: 角标

    /// 左上格式胶囊（扩展名大写；无扩展名时显示来源类型）
    private var formatBadge: some View {
        let text = video.url.pathExtension.uppercased()
        return Text(text.isEmpty ? "URL" : text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(.black.opacity(0.55)))
    }

    /// 右上收藏心（已收藏为鹦鹉黄实心）
    private var favoriteButton: some View {
        Button {
            onToggleFavorite(video)
        } label: {
            Image(systemName: video.isFavorite ? "heart.fill" : "heart")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(video.isFavorite ? Self.parrotYellow : .white)
                .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)
                .padding(6)
                .background(Circle().fill(.black.opacity(0.35)))
        }
        .buttonStyle(.plain)
    }

    // MARK: 封面加载

    /// 异步读取本地封面文件（IO 放后台线程，UIImage 在主线程构建）
    private func loadThumbnail() async {
        guard let relativePath = video.thumbnailPath,
              let fileURL = libraryService.thumbnailURL(forRelativePath: relativePath) else {
            thumbnail = nil
            return
        }
        let data = await Task.detached(priority: .utility) { () -> Data? in
            try? Data(contentsOf: fileURL)
        }.value
        thumbnail = data.flatMap { UIImage(data: $0) }
    }

    // MARK: 私有工具

    /// 占位渐变：按 video.id 哈希在深色渐变组中选一组，保证同一视频稳定
    private var placeholderGradient: some View {
        let palette = Self.gradients[abs(video.id.hashValue) % Self.gradients.count]
        return LinearGradient(colors: palette,
                              startPoint: .topLeading,
                              endPoint: .bottomTrailing)
    }

    /// 深色渐变组（首色 → 尾色）
    private static let gradients: [[Color]] = [
        [Color(red: 0.16, green: 0.18, blue: 0.24), Color(red: 0.07, green: 0.08, blue: 0.11)],
        [Color(red: 0.22, green: 0.17, blue: 0.12), Color(red: 0.08, green: 0.07, blue: 0.06)],
        [Color(red: 0.12, green: 0.20, blue: 0.20), Color(red: 0.06, green: 0.09, blue: 0.10)],
        [Color(red: 0.20, green: 0.14, blue: 0.22), Color(red: 0.08, green: 0.06, blue: 0.10)],
        [Color(red: 0.14, green: 0.16, blue: 0.14), Color(red: 0.07, green: 0.08, blue: 0.07)]
    ]

    /// 主色：鹦鹉黄 #FFC107
    private static let parrotYellow = Color(red: 1.0, green: 0.757, blue: 0.027)

    /// 时长文本（h:mm:ss / mm:ss；未知显示 --:--）
    private static func durationText(_ duration: TimeInterval?) -> String {
        guard let duration, duration.isFinite, duration > 0 else { return "--:--" }
        let total = Int(duration.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// 文件大小文本（未知显示「大小未知」）
    private static func sizeText(_ size: Int64?) -> String {
        guard let size, size > 0 else { return "大小未知" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

// MARK: - 按压缩放按钮样式

/// 按压时缩放到 0.96，松手回弹（不使用系统默认高亮）
private struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
