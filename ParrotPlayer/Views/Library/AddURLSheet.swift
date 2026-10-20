// 文件: AddURLSheet.swift — 添加远程视频弹层：填写直链/标题/字幕地址，解析后入库并立即播放

import SwiftUI

/// 添加远程视频（http/https 直链）
/// - 完成：校验链接 → LibraryViewModel.addRemoteURL → 等待解析结果 → onPlay(新条目, 播放列表) → 关闭
public struct AddURLSheet: View {

    /// 是否展示本弹层（由调用方持有）
    @Binding public var isPresented: Bool
    /// 解析成功后的播放回调
    public let onPlay: (VideoItem, [VideoItem]) -> Void
    /// 轻量回调模式：仅把（地址, 标题）交回调用方自行入库（LibraryView 使用）
    private let onAdd: ((URL, String?) -> Void)?

    @EnvironmentObject private var toastCenter: ToastCenter
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: LibraryViewModel

    /// 视频地址
    @State private var urlText: String = ""
    /// 标题（留空自动获取）
    @State private var titleText: String = ""
    /// 外挂字幕地址（可选）
    @State private var subtitleText: String = ""
    /// 是否正在解析（防止重复提交）
    @State private var isSubmitting: Bool = false

    /// 示例直链（MDN CC0 视频）
    private static let sampleURL = "https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4"

    public init(isPresented: Binding<Bool>, onPlay: @escaping (VideoItem, [VideoItem]) -> Void) {
        self._isPresented = isPresented
        self.onPlay = onPlay
        self.onAdd = nil
        // LibraryViewModel 为 @MainActor 类型，其构造需在运行时完成
        self._viewModel = StateObject(wrappedValue: LibraryViewModel())
    }

    /// 轻量构造：由调用方用 .sheet 控制显隐，提交后通过 onAdd 回调（地址, 标题）
    public init(onAdd: @escaping (URL, String?) -> Void) {
        self._isPresented = .constant(false)
        self.onPlay = { _, _ in }
        self.onAdd = onAdd
        self._viewModel = StateObject(wrappedValue: LibraryViewModel())
    }

    public var body: some View {
        NavigationStack {
            Form {
                linkSection
                tipSection
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("添加远程视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { submit() }
                        .disabled(isSubmitting)
                }
            }
        }
        .overlay {
            if isSubmitting {
                ZStack {
                    Color.black.opacity(0.35)
                    ProgressView("正在解析视频…")
                        .padding(20)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.12, green: 0.12, blue: 0.13)))
                }
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - 表单分区

    private var linkSection: some View {
        Section {
            TextField("https://example.com/video.mp4", text: $urlText)
                .keyboardType(.URL)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .textContentType(.URL)
            TextField("标题", text: $titleText, prompt: Text("留空自动获取"))
            TextField("字幕地址（可选）", text: $subtitleText)
                .keyboardType(.URL)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .textContentType(.URL)
        } header: {
            Text("视频信息")
        }
    }

    private var tipSection: some View {
        Section {
            Button {
                urlText = Self.sampleURL
            } label: {
                Label("填入示例地址", systemImage: "link")
            }
            Text("支持 http/https 直链（mp4/mkv/m3u8 等），网盘直链也可播放")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.55))
        } header: {
            Text("说明")
        }
    }

    // MARK: - 提交

    /// 校验并添加远程视频，解析完成后直接播放
    private func submit() {
        guard !isSubmitting else { return }
        guard let url = normalizedURL() else {
            toastCenter.show("请输入有效的视频地址")
            return
        }
        isSubmitting = true

        let trimmedTitle = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        // 轻量模式：直接把地址与标题交回调用方（由 LibraryView 负责入库与提示）
        if let onAdd {
            onAdd(url, trimmedTitle.isEmpty ? nil : trimmedTitle)
            isPresented = false
            dismiss()
            return
        }
        // 记录提交前已有条目，用于识别解析完成后新增的那一条
        let knownIDs = Set(viewModel.videos.map(\.id))
        let initialError = viewModel.errorMessage

        viewModel.addRemoteURL(url, title: trimmedTitle.isEmpty ? nil : trimmedTitle)

        Task { @MainActor in
            let newItem = await waitForNewItem(excluding: knownIDs, initialError: initialError)
            isSubmitting = false
            guard let newItem else {
                toastCenter.show(viewModel.errorMessage ?? "添加失败：无法解析该视频地址")
                return
            }
            isPresented = false
            onPlay(applySubtitle(to: newItem), playlist(for: newItem))
        }
    }

    /// 规范化输入：补全 https 前缀，仅接受 http/https 且带 host 的链接
    private func normalizedURL() -> URL? {
        let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        var components = URLComponents(string: raw)
        if components?.scheme == nil {
            components = URLComponents(string: "https://" + raw)
        }
        guard let url = components?.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return nil
        }
        return url
    }

    /// 等待 addRemoteURL 内部异步解析完成（轮询媒体库出现新条目，最多约 6 秒）
    @MainActor
    private func waitForNewItem(excluding knownIDs: Set<UUID>, initialError: String?) async -> VideoItem? {
        for _ in 0..<60 {
            if let error = viewModel.errorMessage, error != initialError {
                return nil
            }
            if let found = viewModel.videos.first(where: { !knownIDs.contains($0.id) && $0.kind == .remoteURL }) {
                return found
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    /// 播放列表：优先使用 ViewModel 当前播放列表，否则用媒体库展示列表
    private func playlist(for item: VideoItem) -> [VideoItem] {
        if viewModel.playlist.contains(where: { $0.id == item.id }) {
            return viewModel.playlist
        }
        return viewModel.videos
    }

    /// 挂载用户填写的外挂字幕地址：以 VideoItem.subtitlePath 承载（播放器侧按其加载）
    private func applySubtitle(to item: VideoItem) -> VideoItem {
        let subtitle = subtitleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subtitle.isEmpty else { return item }
        var updated = item
        updated.subtitlePath = subtitle
        return updated
    }
}
