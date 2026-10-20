// 文件: GestureOverlayView.swift — 播放器手势层：单击显隐控件、双击快进快退、横向拖动 seek、
//       左侧竖向调亮度、右侧竖向调音量、双指捏合缩放画面（缩放值通过通知传给视频层）
// 说明：本层位于视频之上、控制条之下；首次移动超过阈值后锁定方向，避免误触；
//       锁定态（viewModel.isLocked）与画中画态下所有手势禁用。

import SwiftUI
import UIKit

public extension Notification.Name {
    /// 画面缩放变化通知（userInfo: ["scale": CGFloat]）
    static let parrotPlayerVideoScale = Notification.Name("ParrotPlayerVideoScale")
}

public struct GestureOverlayView: View {

    // MARK: - 初始化

    public init(viewModel: PlayerViewModel) {
        self.viewModel = viewModel
    }

    @ObservedObject private var viewModel: PlayerViewModel
    @EnvironmentObject private var settingsStore: AppSettingsStore

    // MARK: - 手势状态

    @State private var dragStartLocation: CGPoint?
    @State private var dragAxis: DragAxis?
    @State private var dragStartTime: TimeInterval = 0
    @State private var dragStartBrightness: CGFloat = 0.5
    @State private var dragStartVolume: Float = 0
    @State private var dragStartScale: CGFloat = 1

    @GestureState private var magnification: CGFloat = 1
    @State private var currentScale: CGFloat = 1
    @State private var singleTapTask: Task<Void, Never>?

    // MARK: - HUD 状态

    @State private var hudVisible = false
    @State private var hudTitle: String = ""
    @State private var hudSubtitle: String = ""
    @State private var hudSystemImage: String = ""

    // MARK: - 视图主体

    public var body: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .gesture(dragGesture(in: geometry.size))
                .simultaneousGesture(magnifyGesture)
                .onTapGesture(count: 2) { location in
                    handleDoubleTap(at: location, in: geometry.size)
                }
                .onTapGesture {
                    handleSingleTap()
                }
                .overlay(hudOverlay)
                .onChange(of: magnification) { value in
                    let next = min(max(dragStartScale * value, 1.0), 3.0)
                    currentScale = next
                    NotificationCenter.default.post(
                        name: .parrotPlayerVideoScale,
                        object: nil,
                        userInfo: ["scale": next]
                    )
                }
                .onChange(of: hudVisible) { _ in }
        }
    }

    // MARK: - 拖拽手势

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if dragStartLocation == nil {
                    dragStartLocation = value.startLocation
                    dragStartTime = viewModel.currentTime
                    dragStartBrightness = UIScreen.main.brightness
                    dragStartVolume = viewModel.volume
                    dragAxis = nil
                }
                let translation = value.translation
                if dragAxis == nil {
                    if abs(translation.width) > abs(translation.height) + 4 {
                        dragAxis = .horizontal
                    } else if abs(translation.height) > 4 {
                        dragAxis = .vertical
                    } else {
                        return
                    }
                }
                guard let start = dragStartLocation, let axis = dragAxis else { return }

                switch axis {
                case .horizontal:
                    guard settingsStore.settings.enableSeekGesture else { return }
                    // 整屏宽度对应 90 秒，倍数可按需调整
                    let secondsPerPoint = 90 / max(size.width, 1)
                    var target = dragStartTime + translation.width * secondsPerPoint
                    target = min(max(target, 0), max(viewModel.duration, 0))
                    let delta = target - dragStartTime
                    showHUD(title: PlayerControlsView.timeString(target),
                            subtitle: "\(delta >= 0 ? "快进" : "快退") \(Int(abs(delta))) 秒",
                            systemImage: delta >= 0 ? "goforward" : "gobackward")
                    viewModel.seek(to: target)

                case .vertical:
                    let isLeftHalf = start.x < size.width / 2
                    if isLeftHalf {
                        guard settingsStore.settings.enableBrightnessGesture else { return }
                        let delta = CGFloat(-translation.height / max(size.height, 1)) * 0.8
                        let next = min(max(dragStartBrightness + delta, 0), 1)
                        UIScreen.main.brightness = next
                        showHUD(title: "亮度 \(Int(next * 100))%",
                                subtitle: "", systemImage: "sun.max.fill")
                    } else {
                        guard settingsStore.settings.enableVolumeGesture else { return }
                        let delta = Float(-translation.height / max(size.height, 1)) * 1.2
                        let next = min(max(dragStartVolume + delta, 0), 1)
                        viewModel.setVolume(next)
                        showHUD(title: "音量 \(Int(next * 100))%",
                                subtitle: "", systemImage: next > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    }
                }
            }
            .onEnded { _ in
                dragStartLocation = nil
                dragAxis = nil
                dragStartScale = currentScale
                hideHUD()
            }
    }

    // MARK: - 捏合缩放

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .updating($magnification) { value, state, _ in
                state = value
            }
            .onEnded { value in
                dragStartScale = min(max(currentScale, 1.0), 3.0)
                showHUD(title: "缩放 \(Int(dragStartScale * 100))%",
                        subtitle: "", systemImage: "arrow.up.left.and.arrow.down.right")
            }
    }

    // MARK: - 点击

    private func handleSingleTap() {
        singleTapTask?.cancel()
        singleTapTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { viewModel.controlsVisible.toggle() }
        }
    }

    private func handleDoubleTap(at location: CGPoint, in size: CGSize) {
        singleTapTask?.cancel()
        let isBackward = location.x < size.width / 2
        viewModel.seek(by: isBackward ? -10 : 10)
        showHUD(title: "10 秒",
                subtitle: isBackward ? "快退" : "快进",
                systemImage: isBackward ? "gobackward.10" : "goforward.10")
    }

    // MARK: - HUD

    private var hudOverlay: some View {
        Group {
            if hudVisible {
                VStack(spacing: 6) {
                    Image(systemName: hudSystemImage)
                        .font(.system(size: 26, weight: .semibold))
                    Text(hudTitle)
                        .font(.system(size: 18, weight: .bold).monospacedDigit())
                    if !hudSubtitle.isEmpty {
                        Text(hudSubtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .background(.black.opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: hudVisible)
        .allowsHitTesting(false)
    }

    private func showHUD(title: String, subtitle: String, systemImage: String) {
        hudTitle = title
        hudSubtitle = subtitle
        hudSystemImage = systemImage
        hudVisible = true
        scheduleHideHUD()
    }

    private func hideHUD() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            hudVisible = false
        }
    }

    private func scheduleHideHUD() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            hudVisible = false
        }
    }

    // MARK: - 辅助类型

    private enum DragAxis {
        case horizontal
        case vertical
    }
}
