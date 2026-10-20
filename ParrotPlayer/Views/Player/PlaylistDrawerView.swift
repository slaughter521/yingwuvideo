// 文件: PlaylistDrawerView.swift — 播放列表抽屉：列表切换、系统音量条、AirPlay 路由、清空列表
import AVKit
import MediaPlayer
import SwiftUI

public struct PlaylistDrawerView: View {

    public init(viewModel: PlayerViewModel) {
        self.viewModel = viewModel
    }

    @ObservedObject private var viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 音量与投屏
                HStack(spacing: 14) {
                    Text("音量")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                    SystemVolumeSlider()
                        .frame(height: 24)
                    RoutePicker()
                        .frame(width: 34, height: 34)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider().background(.white.opacity(0.15))

                if viewModel.playlist.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 30))
                            .foregroundStyle(.white.opacity(0.3))
                        Text("播放列表为空")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(Array(viewModel.playlist.enumerated()), id: \.element.id) { index, item in
                            Button {
                                viewModel.load(item, playlist: viewModel.playlist)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Text("\(index + 1)")
                                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(.white.opacity(0.5))
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title)
                                            .font(.system(size: 14))
                                            .foregroundStyle(index == viewModel.currentIndex ? Color.parrotYellow : .white)
                                            .lineLimit(2)
                                        if let duration = item.duration, duration > 0 {
                                            Text(PlayerControlsView.timeString(duration))
                                                .font(.system(size: 11))
                                                .foregroundStyle(.white.opacity(0.45))
                                        }
                                    }
                                    Spacer()
                                    if index == viewModel.currentIndex {
                                        Image(systemName: "waveform")
                                            .font(.system(size: 13))
                                            .foregroundStyle(Color.parrotYellow)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("播放列表（\(viewModel.playlist.count)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("清空") {
                        viewModel.playlist.removeAll()
                        viewModel.currentIndex = 0
                    }
                    .foregroundStyle(.white.opacity(0.7))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - 系统音量条（MPVolumeView）

private struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        view.showsRouteButton = false
        view.tintColor = UIColor(red: 1.0, green: 0.757, blue: 0.027, alpha: 1.0)
        view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

// MARK: - AirPlay 路由按钮（AVRoutePickerView）

private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.activeTintColor = UIColor(red: 1.0, green: 0.757, blue: 0.027, alpha: 1.0)
        picker.tintColor = .white
        picker.prioritizesVideoDevices = true
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
