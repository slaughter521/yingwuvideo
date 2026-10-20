// 文件: ABLoopPanel.swift — AB 循环面板：设置 A/B 点、循环次数、区间可视化、开关循环
import SwiftUI

public struct ABLoopPanel: View {

    public init(viewModel: PlayerViewModel) {
        self.viewModel = viewModel
    }

    @ObservedObject private var viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // 区间可视化
                intervalBar
                    .padding(.horizontal, 24)
                    .padding(.top, 12)

                VStack(spacing: 12) {
                    pointRow(title: "A 点（开始）",
                             value: viewModel.loopA,
                             isEnabled: true,
                             setAction: { viewModel.setABLoop(start: viewModel.currentTime, end: viewModel.loopB) },
                             clearAction: { viewModel.setABLoop(start: nil, end: viewModel.loopB) })

                    pointRow(title: "B 点（结束）",
                             value: viewModel.loopB,
                             isEnabled: viewModel.loopA != nil,
                             setAction: { viewModel.setABLoop(start: viewModel.loopA, end: viewModel.currentTime) },
                             clearAction: { viewModel.setABLoop(start: viewModel.loopA, end: nil) })
                }
                .padding(.horizontal, 24)

                // 循环次数
                VStack(alignment: .leading, spacing: 8) {
                    Text("循环次数")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Stepper(value: Binding(
                        get: { viewModel.sentenceRepeatCount },
                        set: { viewModel.sentenceRepeatCount = max(0, $0) }
                    ), in: 0...99) {
                        HStack {
                            Text(viewModel.sentenceRepeatCount == 0 ? "无限循环" : "重复 \(viewModel.sentenceRepeatCount) 次")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.85))
                            Spacer()
                        }
                    }
                    .tint(Color.parrotYellow)
                }
                .padding(.horizontal, 24)

                // 开关
                Toggle(isOn: Binding(
                    get: { viewModel.loopMode == .ab },
                    set: { enabled in
                        if enabled, viewModel.loopA != nil, viewModel.loopB != nil {
                            viewModel.loopMode = .ab
                        } else if !enabled {
                            viewModel.loopMode = .off
                        }
                    }
                )) {
                    Text("启用 AB 循环")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .tint(Color.parrotYellow)
                .padding(.horizontal, 24)
                .disabled(viewModel.loopA == nil || viewModel.loopB == nil)

                Text("循环播放到 B 点时会自动跳回 A 点；未设置 A/B 点时可先播放到目标位置再点击「设置」")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 24)
                    .multilineTextAlignment(.leading)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("AB 循环")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - 区间可视化

    private var intervalBar: some View {
        GeometryReader { geometry in
            let duration = max(viewModel.duration, 0.001)
            let width = geometry.size.width
            let a = viewModel.loopA.map { min(max($0 / duration, 0), 1) } ?? 0
            let b = viewModel.loopB.map { min(max($0 / duration, 0), 1) } ?? 0

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15)).frame(height: 8)
                if b > a {
                    Capsule().fill(Color.parrotYellow.opacity(0.8))
                        .frame(width: width * (b - a), height: 8)
                        .offset(x: width * a)
                }
                marker("A", at: a, width: width, active: viewModel.loopA != nil)
                marker("B", at: b, width: width, active: viewModel.loopB != nil)
            }
            .frame(height: 26)
        }
        .frame(height: 26)
    }

    private func marker(_ label: String, at fraction: Double, width: CGFloat, active: Bool) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(active ? .black : .white.opacity(0.5))
                .frame(width: 14, height: 14)
                .background(active ? Color.parrotYellow : Color.white.opacity(0.2))
                .clipShape(Circle())
            Rectangle()
                .fill(active ? Color.parrotYellow : Color.white.opacity(0.3))
                .frame(width: 2, height: 14)
        }
        .offset(x: min(max(width * fraction - 7, 0), width - 14))
    }

    // MARK: - 单行

    private func pointRow(title: String,
                         value: TimeInterval?,
                         isEnabled: Bool,
                         setAction: @escaping () -> Void,
                         clearAction: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Text(value.map { PlayerControlsView.timeString($0) } ?? "未设置")
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(value == nil ? .white.opacity(0.4) : Color.parrotYellow)
            Button("设置", action: setAction)
                .font(.system(size: 13, weight: .semibold))
                .disabled(!isEnabled)
                .foregroundStyle(isEnabled ? Color.parrotYellow : .white.opacity(0.3))
            Button("清除", action: clearAction)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
        }
        .buttonStyle(.plain)
    }
}
