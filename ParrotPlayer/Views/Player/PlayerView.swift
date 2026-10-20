// 文件: PlayerView.swift — 全屏播放页：视频层 + 字幕层 + 手势层 + 控制层 + 顶部导航
// 契约（RootView 调用）：PlayerView(video:playlist:onPlaySentence:)
// 说明：视频层使用 AVPlayerViewController（关闭系统控件），以原生支持 AirPlay 与画中画；
//       字幕、手势、控制条均为叠加的 SwiftUI 层，互不遮挡（控件在上、手势在下）。

import AVKit
import SwiftUI

public struct PlayerView: View {

    // MARK: - 初始化（签名固定，勿改）

    public init(video: VideoItem,
                playlist: [VideoItem] = [],
                onPlaySentence: ((TimeInterval) -> Void)? = nil) {
        self.video = video
        self.playlist = playlist
        self.onPlaySentence = onPlaySentence
    }

    private let video: VideoItem
    private let playlist: [VideoItem]
    private let onPlaySentence: ((TimeInterval) -> Void)?

    // MARK: - 状态

    @StateObject private var viewModel = PlayerViewModel()
    /// 学习数据独立实例：播放页加入的生词/收藏会立即写盘，学习页每次出现时重新载入
    @StateObject private var studyViewModel = StudyViewModel()

    @EnvironmentObject private var settingsStore: AppSettingsStore
    @EnvironmentObject private var toastCenter: ToastCenter
    @Environment(\.dismiss) private var dismiss

    @State private var showResumeAlert = false
    @State private var videoScale: CGFloat = 1.0
    @State private var isControlsInteractive = true

    // MARK: - 视图主体

    public var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            // 视频层（画中画激活时隐藏，避免与主画面重复）
            if !viewModel.isPiPActive {
                PlayerContainer(player: viewModel.player, scale: videoScale)
                    .ignoresSafeArea()
                    .overlay {
                        if viewModel.isBuffering {
                            ProgressView()
                                .controlSize(.large)
                                .tint(Color.parrotYellow)
                        }
                    }
            }

            // 字幕层（含点词查词浮层）
            SubtitleDisplayView(
                viewModel: viewModel,
                onAddWord: { entry in
                    studyViewModel.addWord(entry)
                    toastCenter.show("已加入生词本")
                },
                onAddSentence: { favorite in
                    studyViewModel.addFavorite(favorite)
                    toastCenter.show("已收藏句子")
                },
                onPlaySentence: onPlaySentence
            )

            // 手势层（锁定或画中画时禁用）
            if !viewModel.isLocked && !viewModel.isPiPActive {
                GestureOverlayView(viewModel: viewModel)
            }

            // 控制层（顶部导航 + 底部控制条 + 各类面板）
            PlayerControlsView(viewModel: viewModel,
                               onBack: { dismiss() },
                               onScreenshot: takeScreenshot)
        }
        .statusBar(hidden: true)
        .onAppear(perform: setup)
        .onDisappear { viewModel.pause() }
        .alert("继续播放", isPresented: $showResumeAlert) {
            Button("从头开始") {
                viewModel.seek(to: 0)
                viewModel.play()
            }
            Button("继续播放") {
                viewModel.seek(to: video.resumePosition)
                viewModel.play()
            }
        } message: {
            Text("上次观看到 \(Self.formatTime(video.resumePosition))")
        }
        // 错误提示
        .onChange(of: viewModel.errorMessage) { message in
            guard let message else { return }
            toastCenter.show(message)
        }
        // 双指捏合缩放（手势层通过通知传递缩放值）
        .onReceive(NotificationCenter.default.publisher(for: .parrotPlayerVideoScale)) { note in
            guard let scale = note.userInfo?["scale"] as? CGFloat else { return }
            withAnimation(.easeOut(duration: 0.15)) { videoScale = scale }
        }
    }

    // MARK: - 生命周期

    private func setup() {
        // 历史记录注入（断点续播）
        Task { @MainActor in
            viewModel.historyStore = HistoryStore()
            studyViewModel.reload()
            studyViewModel.currentVideoTitle = video.title
        }
        viewModel.load(video, playlist: playlist)

        // 自动挂载外挂字幕
        if let subtitlePath = video.subtitlePath, !subtitlePath.isEmpty {
            let url = subtitlePath.hasPrefix("/") ? URL(fileURLWithPath: subtitlePath)
                : URL(fileURLWithPath: subtitlePath)
            viewModel.loadSubtitle(from: url)
        }

        // 断点续播提示（超过 5 秒才询问）
        if settingsStore.settings.resumePlayback, video.resumePosition > 5 {
            showResumeAlert = true
        } else {
            viewModel.play()
        }
    }

    // MARK: - 截图

    private func takeScreenshot() {
        viewModel.captureScreenshot { image in
            guard let image else {
                toastCenter.show("截图失败：无法读取当前画面")
                return
            }
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            toastCenter.show("截图已保存到相册")
        }
    }

    // MARK: - 工具

    public static func formatTime(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "00:00" }
        let total = Int(interval)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - 视频层（AVPlayerViewController 包装）

/// 使用 AVPlayerViewController 承载播放：保留 AirPlay / 画中画能力，同时隐藏系统控件
private struct PlayerContainer: UIViewControllerRepresentable {
    let player: AVPlayer
    let scale: CGFloat

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.updatesNowPlayingInfoCenter = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        controller.view.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player = nil
    }
}
