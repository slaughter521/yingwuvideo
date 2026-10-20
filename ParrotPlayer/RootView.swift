// 文件: RootView.swift — Tab 根视图（媒体库/学习/设置）+ 全局 Toast 中心 + 播放器全屏挂载点

import SwiftUI

/// 全局 Toast 提示中心：以 EnvironmentObject 注入，各模块均可调用 show(_:)
public final class ToastCenter: ObservableObject {
    /// 当前 Toast 文案（nil 表示不显示）
    @Published public var message: String?

    public init() {}

    /// 显示一条 Toast 文案
    public func show(_ message: String) {
        self.message = message
    }

    /// 隐藏当前 Toast
    public func dismiss() {
        message = nil
    }
}

public struct RootView: View {
    // MARK: - 播放器全屏挂载点

    /// 当前全屏播放的视频项（nil 表示播放页未展示）
    @State private var playerItem: VideoItem?
    /// 播放页对应的播放列表（与 playerItem 一起设置）
    @State private var playerPlaylist: [VideoItem] = []

    var body: some View {
        TabView {
            LibraryView(onPlay: handlePlay)
                .tabItem {
                    Label("媒体库", systemImage: "square.grid.2x2")
                }
            StudyView()
                .tabItem {
                    Label("学习", systemImage: "book")
                }
            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gear")
                }
        }
        // 播放器契约（由 agent-player 实现，此处只引用不修改）：
        // PlayerView(video: VideoItem, playlist: [VideoItem] = [], onPlaySentence: ((TimeInterval) -> Void)? = nil)
        .fullScreenCover(item: $playerItem) { item in
            PlayerView(video: item, playlist: playerPlaylist)
        }
    }

    /// LibraryView 的播放请求回调（签名固定，由 LibraryView 调用，勿改）
    private func handlePlay(_ video: VideoItem, _ playlist: [VideoItem]) {
        playerPlaylist = playlist
        playerItem = video
    }
}
