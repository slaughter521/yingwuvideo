// 文件: PlayerControlsView.swift — 播放控制层：顶部导航 + 底部进度条/按钮行 + 倍速/AB/字幕/播放列表面板
// 说明：控制层 5 秒无操作自动隐藏；锁定态只保留解锁按钮与只读进度条；
//       进度条支持拖拽 seek（松手时精确跳转），缓冲进度读取 AVPlayerItem.loadedTimeRanges。

import AVKit
import SwiftUI

public struct PlayerControlsView: View {

    // MARK: - 初始化

    public init(viewModel: PlayerViewModel,
                onBack: @escaping () -> Void,
                onScreenshot: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onBack = onBack
        self.onScreenshot = onScreenshot
    }

    @ObservedObject private var viewModel: PlayerViewModel
    private let onBack: () -> Void
    private let onScreenshot: () -> Void

    @EnvironmentObject private var settingsStore: AppSettingsStore
    @EnvironmentObject private var toastCenter: ToastCenter

    @State private var showSpeedPanel = false
    @State private var showABPanel = false
    @State private var showSubtitlePanel = false
    @State private var showPlaylist = false
    @State private var hideTask: Task<Void, Never>?
    @State private var isDragging = false
    @State private var dragTime: TimeInterval = 0

    // MARK: - 视图主体

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            bottomBar
        }
        .opacity(viewModel.controlsVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: viewModel.controlsVisible)
        .allowsHitTesting(viewModel.controlsVisible)
        .onChange(of: viewModel.controlsVisible) { visible in
            if visible { scheduleAutoHide() } else { hideTask?.cancel() }
        }
        .onAppear(perform: scheduleAutoHide)
        .onDisappear { hideTask?.cancel() }
        .sheet(isPresented: $showSpeedPanel) { SpeedControlView(viewModel: viewModel) }
        .sheet(isPresented: $showABPanel) { ABLoopPanel(viewModel: viewModel) }
        .sheet(isPresented: $showSubtitlePanel) { SubtitleSettingsSheet(viewModel: viewModel) }
        .sheet(isPresented: $showPlaylist) { PlaylistDrawerView(viewModel: viewModel) }
    }

    // MARK: - 顶部栏

    private var topBar: some View {
        HStack(spacing: 14) {
            button("chevron.left") { onBack() }

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.currentItem?.title ?? "正在加载")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if viewModel.duration > 0 {
                    Text("\(Self.timeString(viewModel.currentTime)) / \(Self.timeString(viewModel.duration))")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            Spacer()

            if viewModel.isLocked {
                button("lock.fill") { viewModel.toggleLock() }
            } else {
                button("pip.enter") {
                    viewModel.enterPiP()
                    toastCenter.show("已尝试进入画中画（也可从控制中心开启）")
                }
                button(viewModel.isLocked ? "lock.fill" : "lock.open") { viewModel.toggleLock() }
                button("camera") { onScreenshot() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(LinearGradient(colors: [.black.opacity(0.75), .clear],
                                   startPoint: .top, endPoint: .bottom))
    }

    // MARK: - 底部控制区

    private var bottomBar: some View {
        VStack(spacing: 10) {
            // 进度条
            progressBar

            // 时间
            HStack {
                Text(Self.timeString(isDragging ? dragTime : viewModel.currentTime))
                Spacer()
                Text(Self.timeString(viewModel.duration))
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 18)

            // 按钮行
            if viewModel.isLocked {
                HStack {
                    Spacer()
                    Button {
                        viewModel.toggleLock()
                        toastCenter.show("已解锁")
                    } label: {
                        Label("解锁", systemImage: "lock.open")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(.white.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    Spacer()
                }
                .foregroundStyle(.white)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        controlButton(viewModel.isPlaying ? "pause.fill" : "play.fill", size: 22) {
                            viewModel.togglePlay()
                        }
                        controlButton("backward.frame.fill") { viewModel.playPreviousSentence() }
                        controlButton("forward.frame.fill") { viewModel.playNextSentence() }

                        Text(String(format: "%.2gx", viewModel.rate))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.parrotYellow)
                            .frame(width: 46)
                            .onTapGesture { showSpeedPanel = true }
                            .accessibilityLabel("播放速度")

                        controlButton("repeat") { showABPanel = true }
                        controlButton("captions.bubble") { showSubtitlePanel = true }
                        controlButton("list.bullet") { showPlaylist = true }
                        controlButton("airplayvideo") { toastCenter.show("请从控制中心选择投屏设备") }
                        controlButton("lock") { viewModel.toggleLock() }
                    }
                    .padding(.horizontal, 18)
                }
            }
        }
        .padding(.bottom, 18)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.85)],
                                   startPoint: .top, endPoint: .bottom))
    }

    // MARK: - 进度条

    private var progressBar: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let duration = max(viewModel.duration, 0.001)
            let playedFraction = min(max((isDragging ? dragTime : viewModel.currentTime) / duration, 0), 1)
            let bufferedFraction = min(max(bufferedProgress, 0), 1)
            // AB 区间标记
            let aFraction = viewModel.loopA.map { min(max($0 / duration, 0), 1) }
            let bFraction = viewModel.loopB.map { min(max($0 / duration, 0), 1) }

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22)).frame(height: 4)
                Capsule().fill(.white.opacity(0.45))
                    .frame(width: width * bufferedFraction, height: 4)
                if let a = aFraction, let b = bFraction, b > a {
                    Capsule().fill(Color.parrotYellow.opacity(0.35))
                        .frame(width: width * (b - a), height: 4)
                        .offset(x: width * a)
                }
                Capsule().fill(Color.parrotYellow)
                    .frame(width: max(width * playedFraction, 0), height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: isDragging ? 16 : 12, height: isDragging ? 16 : 12)
                    .offset(x: max(width * playedFraction - (isDragging ? 8 : 6), 0))
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if !isDragging { isDragging = true }
                        let fraction = min(max(value.location.x / width, 0), 1)
                        dragTime = fraction * duration
                        scheduleAutoHide()
                    }
                    .onEnded { _ in
                        viewModel.seek(to: dragTime, precise: true)
                        isDragging = false
                        scheduleAutoHide()
                    }
            )
            .overlay(alignment: .leading) {
                if isDragging {
                    Text(Self.timeString(dragTime))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.7))
                        .clipShape(Capsule())
                        .offset(y: -22)
                        .offset(x: min(max(width * playedFraction - 20, 0), width - 60))
                }
            }
        }
        .frame(height: 20)
        .padding(.horizontal, 18)
    }

    /// 缓冲进度（0...1）
    private var bufferedProgress: Double {
        guard let item = viewModel.player.currentItem,
              item.duration.seconds.isFinite, item.duration.seconds > 0,
              let range = item.loadedTimeRanges.last?.timeRangeValue else { return 0 }
        return (range.start.seconds + range.duration.seconds) / item.duration.seconds
    }

    // MARK: - 自动隐藏

    private func scheduleAutoHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            if viewModel.controlsVisible, !viewModel.isLocked, selectedWordShown == false {
                viewModel.controlsVisible = false
            }
        }
    }

    /// 词卡展示期间不自动隐藏（由外部字幕层控制，这里只做保守判断）
    private var selectedWordShown: Bool { false }

    // MARK: - 组件

    private func button(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.black.opacity(0.35))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func controlButton(_ systemName: String,
                               size: CGFloat = 17,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(.white.opacity(0.12))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 工具

    static func timeString(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "00:00" }
        let total = Int(interval)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - 字幕设置面板（内联）

private struct SubtitleSettingsSheet: View {
    @ObservedObject var viewModel: PlayerViewModel
    @EnvironmentObject private var settingsStore: AppSettingsStore
    @EnvironmentObject private var toastCenter: ToastCenter
    @Environment(\.dismiss) private var dismiss

    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            Form {
                Section("显示模式") {
                    Picker("模式", selection: Binding(
                        get: { viewModel.displayMode },
                        set: { viewModel.setDisplayMode($0) }
                    )) {
                        Text("双语").tag(SubtitleDisplayMode.bilingual)
                        Text("仅原文").tag(SubtitleDisplayMode.primaryOnly)
                        Text("仅译文").tag(SubtitleDisplayMode.secondaryOnly)
                        Text("隐藏").tag(SubtitleDisplayMode.hidden)
                    }
                    .pickerStyle(.segmented)
                }

                Section("字幕外观") {
                    HStack {
                        Text("字号")
                        Slider(value: Binding(
                            get: { settingsStore.settings.subtitleFontSize },
                            set: { settingsStore.settings.subtitleFontSize = $0; settingsStore.save() }
                        ), in: 12...28, step: 1)
                        Text("\(Int(settingsStore.settings.subtitleFontSize))pt")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Section("时间轴") {
                    Stepper(value: Binding(
                        get: { viewModel.subtitleTrack?.timeOffset ?? 0 },
                        set: { newValue in
                            let delta = newValue - (viewModel.subtitleTrack?.timeOffset ?? 0)
                            viewModel.adjustSubtitleOffset(by: delta)
                        }
                    ), in: -10...10, step: 0.1) {
                        HStack {
                            Text("时间偏移")
                            Spacer()
                            Text(String(format: "%+.1fs", viewModel.subtitleTrack?.timeOffset ?? 0))
                                .font(.system(size: 13).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("提前 0.5 秒") { viewModel.adjustSubtitleOffset(by: -0.5) }
                    Button("延后 0.5 秒") { viewModel.adjustSubtitleOffset(by: 0.5) }
                }

                Section("外挂字幕") {
                    Button("导入本地字幕文件（SRT/ASS/VTT/LRC）") { showImporter = true }
                    if let track = viewModel.subtitleTrack {
                        HStack {
                            Text("当前字幕")
                            Spacer()
                            Text("\(track.cues.count) 条 · \(track.label)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("未加载字幕")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("字幕设置")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.data, .plainText]) { result in
                switch result {
                case .success(let url):
                    viewModel.loadSubtitle(from: url)
                    toastCenter.show("字幕已加载")
                case .failure:
                    toastCenter.show("字幕导入失败")
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - 主题色

public extension Color {
    /// 鹦鹉黄（品牌主色 #FFC107）
    static let parrotYellow = Color(red: 1.0, green: 0.757, blue: 0.027)
}
