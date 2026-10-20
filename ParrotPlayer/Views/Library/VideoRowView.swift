// 文件: VideoRowView.swift — 媒体库列表行：缩略图 + 标题/信息行 + 操作菜单 + 观看进度条 + 滑动操作
//
// 设计约束：全部数据由外部以闭包传入，不依赖任何 ViewModel，便于在网格/列表/搜索结果等场景复用。
// 被 LibraryView（列表模式）以 ForEach 方式使用；也可直接放进 List 使用（listRowBackground / swipeActions 生效）。

import SwiftUI
import UIKit

public struct VideoRowView: View {

    // MARK: - 输入

    public let video: VideoItem
    /// 缩略图本地文件 URL（由 LibraryService.thumbnailURL(forRelativePath:) 解析得到）
    public let thumbnailURL: URL?
    public let onPlay: () -> Void
    public let onToggleFavorite: () -> Void
    public let onDelete: () -> Void
    public let onExportAudio: () -> Void

    // MARK: - 内部状态

    /// 异步加载的缩略图；nil 时展示占位图标
    @State private var thumbnailImage: UIImage?

    public init(video: VideoItem,
                thumbnailURL: URL?,
                onPlay: @escaping () -> Void,
                onToggleFavorite: @escaping () -> Void,
                onDelete: @escaping () -> Void,
                onExportAudio: @escaping () -> Void) {
        self.video = video
        self.thumbnailURL = thumbnailURL
        self.onPlay = onPlay
        self.onToggleFavorite = onToggleFavorite
        self.onDelete = onDelete
        self.onExportAudio = onExportAudio
    }

    public var body: some View {
        HStack(spacing: 12) {
            thumbnail
            textInfo
            menu
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
        .overlay(alignment: .bottom) { progressBar }
        .listRowBackground(Color.ppRowBackground)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                onToggleFavorite()
            } label: {
                Label(video.isFavorite ? "取消收藏" : "收藏",
                      systemImage: video.isFavorite ? "heart.slash.fill" : "heart.fill")
            }
            .tint(.ppAccent)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("删除", systemImage: "trash.fill")
            }
        }
        // 行复用时按 video.id 重新加载并校验，避免串图
        .task(id: video.id) {
            await loadThumbnail()
        }
    }

    // MARK: - 子组件

    /// 80x45 圆角缩略图；加载失败/无封面时展示 SF Symbol「film」
    private var thumbnail: some View {
        Group {
            if let thumbnailImage {
                Image(uiImage: thumbnailImage)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.ppFallbackBackground
                    Image(systemName: "film")
                        .font(.system(size: 16))
                        .foregroundStyle(.gray)
                }
            }
        }
        .frame(width: 80, height: 45)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// 标题（1 行）+ 信息行（格式 · 大小 · 时长 · 收藏）
    private var textInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(video.title)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(1)
                .foregroundStyle(.primary)

            HStack(spacing: 5) {
                Text(formatText)
                Text("·")
                Text(sizeText)
                Text("·")
                Text(Self.formatTime(video.duration))
                if video.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(.ppAccent)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    /// 右侧操作菜单：播放 / 收藏 / 导出音频 / 删除
    private var menu: some View {
        Menu {
            Button {
                onPlay()
            } label: {
                Label("播放", systemImage: "play.fill")
            }
            Button {
                onToggleFavorite()
            } label: {
                Label(video.isFavorite ? "取消收藏" : "收藏",
                      systemImage: video.isFavorite ? "heart.slash" : "heart")
            }
            Button {
                onExportAudio()
            } label: {
                Label("导出音频", systemImage: "waveform")
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("删除", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    /// 底部观看进度细条（续播进度大于 2% 时展示）
    @ViewBuilder
    private var progressBar: some View {
        if progress > 0.02 {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Color.white.opacity(0.10)
                    Color.ppAccent
                        .frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 2)
        }
    }

    // MARK: - 数据格式化

    /// 观看进度（0...1）
    private var progress: Double {
        guard let duration = video.duration, duration > 0 else { return 0 }
        return min(max(video.resumePosition / duration, 0), 1)
    }

    /// 格式：文件扩展名大写，缺失时回退来源类型
    private var formatText: String {
        let ext = video.url.pathExtension.uppercased()
        return ext.isEmpty ? "未知格式" : ext
    }

    /// 文件大小（ByteCountFormatter）；未知时给出占位
    private var sizeText: String {
        guard let fileSize = video.fileSize, fileSize > 0 else { return "大小未知" }
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    /// 时长格式化：mm:ss（超过 1 小时为 h:mm:ss）；未知返回 "--:--"
    private static func formatTime(_ time: TimeInterval?) -> String {
        guard let time, time.isFinite, time > 0 else { return "--:--" }
        let total = Int(time.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - 缩略图加载

    /// 后台线程读取图片文件，回到主线程赋值；以 video.id 校验当前行未被复用
    private func loadThumbnail() async {
        guard let thumbnailURL else {
            thumbnailImage = nil
            return
        }
        let targetID = video.id
        let data = await Task.detached(priority: .utility) { () -> Data? in
            try? Data(contentsOf: thumbnailURL)
        }.value
        guard targetID == video.id else { return }
        thumbnailImage = data.flatMap { UIImage(data: $0) }
    }
}

// MARK: - 主题色

private extension Color {
    /// 行背景 #1C1C1E
    static let ppRowBackground = Color(red: 0.110, green: 0.110, blue: 0.118)
    /// 缩略图占位底色（比行背景更浅一档）
    static let ppFallbackBackground = Color(red: 0.17, green: 0.17, blue: 0.18)
    /// 强调色（鹦鹉黄）#FFC207
    static let ppAccent = Color(red: 1.0, green: 0.761, blue: 0.027)
}
