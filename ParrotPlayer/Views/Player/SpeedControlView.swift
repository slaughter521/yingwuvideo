// 文件: SpeedControlView.swift — 倍速控制面板：0.2~2.5 无级调节 + 常用预设
import SwiftUI

public struct SpeedControlView: View {

    public init(viewModel: PlayerViewModel) {
        self.viewModel = viewModel
    }

    @ObservedObject private var viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    private let presets: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    public var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                // 当前倍速
                VStack(spacing: 6) {
                    Text(String(format: "%.2fx", viewModel.rate))
                        .font(.system(size: 44, weight: .bold).monospacedDigit())
                        .foregroundStyle(Color.parrotYellow)
                    Text("拖动滑块可无级变速（0.2x ~ 2.5x）")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.top, 12)

                Slider(
                    value: Binding(
                        get: { Double(viewModel.rate) },
                        set: { viewModel.setRate(Float($0)) }
                    ),
                    in: 0.2...2.5,
                    step: 0.05
                )
                .tint(Color.parrotYellow)
                .padding(.horizontal, 24)

                HStack {
                    Text("0.2x").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    Text("2.5x").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 26)

                // 预设
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(presets, id: \.self) { preset in
                        Button {
                            viewModel.setRate(preset)
                        } label: {
                            Text(String(format: "%.2gx", preset))
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(abs(viewModel.rate - preset) < 0.03
                                            ? Color.parrotYellow
                                            : Color.white.opacity(0.1))
                                .foregroundStyle(abs(viewModel.rate - preset) < 0.03 ? .black : .white)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)

                Button {
                    viewModel.setRate(1.0)
                } label: {
                    Text("恢复正常速度")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.8))
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("播放速度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
