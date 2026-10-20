// 文件: LibraryView.swift — 媒体库主页：导入/URL/网盘入口、继续观看区、排序与视图切换、网格/列表媒体展示、空态与删除确认
//
// 环境依赖：ToastCenter / AppSettingsStore 由 ParrotPlayerApp 通过 .environmentObject 注入（见 ParrotPlayerApp.swift），
// 本视图以 @EnvironmentObject 读取，不自行创建。
//
// 并行任务依赖（由其他任务创建，签名约定如下，请勿改动）：
// - PosterWallView(videos: [VideoItem],
//                  thumbnailURL: @escaping (VideoItem) -> URL?,
//                  onPlay: @escaping (VideoItem) -> Void,
//                  onToggleFavorite: @escaping (VideoItem) -> Void,
//                  onDelete: @escaping (VideoItem) -> Void)
// - AddURLSheet(onAdd: @escaping (URL, String?) -> Void)
// - VideoRowView 见同目录 VideoRowView.swift（本任务一并实现）

import SwiftUI
import UIKit
import UniformTypeIdentifiers

public struct LibraryView: View {

    // MARK: - 环境依赖（由 App 注入）

    /// 全局 Toast 提示中心
    @EnvironmentObject private var toastCenter: ToastCenter
    /// 全局设置（用于读取「断点续播」开关等）
    @EnvironmentObject private var settingsStore: AppSettingsStore
    /// 场景生命周期：回到前台时重新扫描
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - ViewModel

    @StateObject private var viewModel = LibraryViewModel()

    /// 播放请求回调（契约签名固定，与 RootView.handlePlay 同构）
    private let onPlay: (VideoItem, [VideoItem]) -> Void

    // MARK: - 面板 / 弹窗状态

    /// 文件导入面板
    @State private var showingFileImporter = false
    /// 添加远程链接面板
    @State private var showingURLSheet = false
    /// 网盘接入面板
    @State private var showingCloudSheet = false
    /// 待确认删除的媒体项（非空时弹出确认框）
    @State private var pendingDeleteVideo: VideoItem?

    /// 缩略图路径解析：thumbnailURL(forRelativePath:) 是 LibraryService 的具体方法（非 LibraryServicing 协议方法），
    /// 因此单独持有一个解析器实例，仅用于把 VideoItem.thumbnailPath 转换为完整文件 URL。
    private let thumbnailResolver = LibraryService()
    /// 网盘列表来源
    private let networkService = NetworkVideoService()

    public init(onPlay: @escaping (VideoItem, [VideoItem]) -> Void) {
        self.onPlay = onPlay
    }

    // MARK: - 主体

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle("媒体库")
                .toolbar { toolbarContent }
                .searchable(text: $viewModel.searchText, prompt: "搜索视频")
                .background(Color.black.ignoresSafeArea())
                .sheet(isPresented: $showingURLSheet) {
                    AddURLSheet { url, title in
                        // 签名约定：AddURLSheet(onAdd: @escaping (URL, String?) -> Void)
                        viewModel.addRemoteURL(url, title: title)
                        toastCenter.show("已添加远程视频")
                    }
                }
                .sheet(isPresented: $showingCloudSheet) {
                    CloudDriveSheet(providers: networkService.cloudProviders()) { providerID in
                        authorize(providerID: providerID)
                    }
                }
                .fileImporter(isPresented: $showingFileImporter,
                              allowedContentTypes: [.item],
                              allowsMultipleSelection: false) { result in
                    handleImport(result)
                }
                // 错误提示挂在最外层；删除确认挂在列表主体上，避免同层级两个 alert 相互覆盖
                .alert("出错了", isPresented: isErrorAlertPresented) {
                    Button("知道了", role: .cancel) { viewModel.errorMessage = nil }
                } message: {
                    Text(viewModel.errorMessage ?? "")
                }
                .onAppear {
                    viewModel.refresh()
                }
                .onChange(of: scenePhase) { phase in
                    guard phase == .active else { return }
                    // 回到前台：重新扫描并同步播放记录（refresh() 内部已刷新记录，再次调用保证 UI 与历史一致）
                    viewModel.refresh()
                    viewModel.refreshRecentRecords()
                }
        }
    }

    // 以下成员均访问 @MainActor 的 LibraryViewModel，故显式标注 @MainActor（View.body 本身即运行在主线程）
    @MainActor
    @ViewBuilder
    private var content: some View {
        if viewModel.videos.isEmpty {
            // 搜索无结果时给出针对性提示，其余情况展示媒体库空态
            if viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptyState
            } else {
                noResultsState
            }
        } else {
            VStack(spacing: 0) {
                if showsContinueWatching { continueWatchingSection }
                toolBar
                libraryBody
            }
        }
    }

    /// 网格模式交给 PosterWallView（自带滚动），列表模式用 ScrollView + LazyVStack 逐行渲染
    @MainActor
    @ViewBuilder
    private var libraryBody: some View {
        Group {
            if viewModel.viewMode == .grid {
                PosterWallView(
                    videos: viewModel.videos,
                    onPlay: { video, _ in play(video) },
                    onToggleFavorite: { toggleFavorite($0) },
                    onDelete: { requestDelete($0) },
                    onExportAudio: { exportAudio(for: $0) }
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.videos) { video in
                            VideoRowView(
                                video: video,
                                thumbnailURL: thumbnailURL(for: video),
                                onPlay: { play(video) },
                                onToggleFavorite: { toggleFavorite(video) },
                                onDelete: { requestDelete(video) },
                                onExportAudio: { exportAudio(for: video) }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                }
            }
        }
        // 删除确认框：与外层的错误提示 alert 分层挂载，避免同层级弹窗互相覆盖
        .alert("删除视频", isPresented: isDeleteAlertPresented, presenting: pendingDeleteVideo) { video in
            Button("删除", role: .destructive) {
                viewModel.deleteVideo(video)
                pendingDeleteVideo = nil
                toastCenter.show("已删除「\(video.title)」")
            }
            Button("取消", role: .cancel) { pendingDeleteVideo = nil }
        } message: { video in
            Text("「\(video.title)」将从媒体库中移除，本地文件与播放记录一并删除，此操作不可撤销。")
        }
    }

    // MARK: - 工具栏

    private var toolbarContent: some ToolbarContent {
        Group {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    showingFileImporter = true
                } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                }
                .tint(.ppAccent)
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    showingURLSheet = true
                } label: {
                    Label("URL", systemImage: "link")
                }
                .tint(.ppAccent)
                Button {
                    showingCloudSheet = true
                } label: {
                    Label("网盘", systemImage: "externaldrive")
                }
                .tint(.ppAccent)
            }
        }
    }

    /// 排序 Menu + 网格/列表切换
    @MainActor
    private var toolBar: some View {
        HStack(spacing: 12) {
            Menu {
                Picker("排序方式", selection: $viewModel.sortOrder) {
                    ForEach(LibrarySortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("排序", systemImage: "arrow.up.arrow.down")
                    .font(.subheadline)
            }
            .tint(.ppAccent)

            Spacer(minLength: 0)

            Picker("展示方式", selection: $viewModel.viewMode) {
                Image(systemName: "square.grid.2x2").tag(LibraryViewMode.grid)
                Image(systemName: "list.bullet").tag(LibraryViewMode.list)
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - 继续观看

    /// 仅在开启断点续播且存在符合条件的记录时展示
    @MainActor
    private var showsContinueWatching: Bool {
        settingsStore.settings.resumePlayback && !viewModel.continueWatchingItems.isEmpty
    }

    @MainActor
    private var continueWatchingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("继续观看")
                .font(.headline)
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(viewModel.continueWatchingItems) { item in
                        ContinueWatchingCard(
                            video: item,
                            record: record(for: item),
                            thumbnailURL: thumbnailURL(for: item)
                        ) {
                            play(item)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("媒体库空空如也")
                .font(.headline)
            Text("导入视频或添加远程地址，开始外语学习")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button {
                    showingFileImporter = true
                } label: {
                    Label("导入视频", systemImage: "square.and.arrow.down")
                }
                Button {
                    showingURLSheet = true
                } label: {
                    Label("添加链接", systemImage: "link")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.ppAccent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor
    private var noResultsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("没有找到匹配的视频")
                .font(.headline)
            Text("换个关键词试试，或清空搜索框查看全部媒体")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 交互

    /// 播放：先让 ViewModel 设置播放列表与下标，再回调外层全屏播放
    /// 说明：viewModel.onPlay 由外部调度方按需注入，本视图不重复赋值，避免二次触发
    @MainActor
    private func play(_ video: VideoItem) {
        if let index = viewModel.videos.firstIndex(where: { $0.id == video.id }) {
            viewModel.startPlayback(at: index)
            let playlist = viewModel.playlist
            let item = playlist.indices.contains(index) ? playlist[index] : video
            onPlay(item, playlist)
        } else {
            // 搜索过滤等场景下该项不在展示列表中，按单项播放
            onPlay(video, [video])
        }
    }

    @MainActor
    private func toggleFavorite(_ video: VideoItem) {
        viewModel.toggleFavorite(video)
        toastCenter.show(video.isFavorite ? "已取消收藏" : "已加入收藏")
    }

    /// 记录待删除项，由 .alert 弹出确认框
    private func requestDelete(_ video: VideoItem) {
        pendingDeleteVideo = video
    }

    @MainActor
    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // importFromDocument 内部异步执行，随后刷新列表以纳入新扫描到的文件
            viewModel.importFromDocument(url: url)
            viewModel.refresh()
            toastCenter.show("已导入「\(url.deletingPathExtension().lastPathComponent)」")
        case .failure(let error):
            toastCenter.show("导入失败：\(error.localizedDescription)")
        }
    }

    /// 按 providerID 重新解析出 provider 再授权（Task 内不捕获非 Sendable 的协议存在体）
    @MainActor
    private func authorize(providerID: String) {
        let providers = networkService.cloudProviders()
        let providerName = providers.first(where: { $0.id == providerID })?.name ?? "网盘"
        Task { @MainActor in
            guard let provider = providers.first(where: { $0.id == providerID }) else { return }
            do {
                try await provider.authorize()
                toastCenter.show("已授权「\(providerName)」")
            } catch {
                toastCenter.show("\(providerName)授权失败：\(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private func exportAudio(for video: VideoItem) {
        Task { @MainActor in
            do {
                let service = ExportService()
                let fileURL = try await service.exportAudio(from: video)
                toastCenter.show("已导出音频：\(fileURL.lastPathComponent)")
            } catch {
                toastCenter.show("导出失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 辅助

    /// VideoItem.thumbnailPath（相对路径）→ 完整文件 URL
    private func thumbnailURL(for video: VideoItem) -> URL? {
        guard let relativePath = video.thumbnailPath else { return nil }
        return thumbnailResolver.thumbnailURL(forRelativePath: relativePath)
    }

    /// 取该视频最近一条播放记录（用于进度与剩余时长）
    @MainActor
    private func record(for video: VideoItem) -> PlaybackRecord? {
        viewModel.recentRecords.first { $0.videoID == video.id }
    }

    private var isDeleteAlertPresented: Binding<Bool> {
        Binding(
            get: { pendingDeleteVideo != nil },
            set: { if !$0 { pendingDeleteVideo = nil } }
        )
    }

    @MainActor
    private var isErrorAlertPresented: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}

// MARK: - 继续观看卡片

/// 横向「继续观看」卡片：16:9 缩略图 + 标题 + 进度条 + 剩余时长
private struct ContinueWatchingCard: View {

    let video: VideoItem
    let record: PlaybackRecord?
    let thumbnailURL: URL?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                RemoteThumbnail(url: thumbnailURL, videoID: video.id)
                    .frame(width: 200, height: 200 * 9.0 / 16.0)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(video.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(2)
                        .foregroundStyle(.primary)

                    ProgressView(value: min(max(progress, 0), 1))
                        .tint(.ppAccent)

                    Text(remainingText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 200)
        }
        .buttonStyle(.plain)
    }

    /// 播放进度（0...1），无记录时回退到 VideoItem 自带的续播位置
    private var progress: Double {
        if let record { return record.progress }
        guard let duration = video.duration, duration > 0 else { return 0 }
        return video.resumePosition / duration
    }

    /// 「剩余 x 分钟」，不足 1 分钟按 1 分钟显示
    private var remainingText: String {
        guard let record else {
            guard let duration = video.duration else { return "剩余时间未知" }
            return "剩余 \(Self.minutes(ceil(max(duration - video.resumePosition, 0) / 60))) 分钟"
        }
        return "剩余 \(Self.minutes(ceil(max(record.duration - record.position, 0) / 60))) 分钟"
    }

    /// 分钟数格式化（不足 1 分钟按 1 分钟计）
    private static func minutes(_ value: Double) -> Int {
        max(Int(value.rounded(.up)), value > 0 ? 1 : 0)
    }
}

// MARK: - 异步缩略图

/// 按文件路径异步加载缩略图；以 videoID 校验，避免列表复用时串图
private struct RemoteThumbnail: View {

    let url: URL?
    let videoID: UUID

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.ppCardBackground
                    Image(systemName: "film")
                        .font(.system(size: 20))
                        .foregroundStyle(.gray)
                }
            }
        }
        .task(id: videoID) {
            await load()
        }
    }

    private func load() async {
        guard let url else {
            image = nil
            return
        }
        let targetID = videoID
        // 磁盘读取放到后台线程，避免滑动卡顿
        let data = await Task.detached(priority: .utility) { () -> Data? in
            try? Data(contentsOf: url)
        }.value
        guard targetID == videoID else { return }
        image = data.flatMap { UIImage(data: $0) }
    }
}

// MARK: - 网盘授权面板

/// 网盘接入面板：列出 CloudProvider，点击发起授权，失败以 Toast 反馈
private struct CloudDriveSheet: View {

    let providers: [CloudProvider]
    /// 参数为 provider.id：不把协议存在体（非 Sendable）传进异步任务
    let onAuthorize: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // 用下标遍历：避免对协议存在体取 key path
                    ForEach(providers.indices, id: \.self) { index in
                        let provider = providers[index]
                        Button {
                            onAuthorize(provider.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "externaldrive.fill")
                                    .foregroundStyle(.ppAccent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(provider.name)
                                        .foregroundStyle(.primary)
                                    Text(provider.isAuthorized ? "已授权" : "未授权")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tint(.primary)
                    }
                } header: {
                    Text("支持的网络云盘")
                } footer: {
                    Text("网盘接入首期为占位实现，需完成 OAuth 配置后即可浏览并播放云端视频。")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("网盘")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .tint(.ppAccent)
                }
            }
        }
    }
}

// MARK: - 主题色

private extension Color {
    /// 卡片背景 #1C1C1E
    static let ppCardBackground = Color(red: 0.110, green: 0.110, blue: 0.118)
    /// 强调色（鹦鹉黄）#FFC207
    static let ppAccent = Color(red: 1.0, green: 0.761, blue: 0.027)
}
