// 文件: SentenceFavoritesView.swift — 句子收藏列表页
// 职责：展示 StudyViewModel.sentenceFavorites（主字幕白 16pt / 次字幕黄 14pt / 视频名 / 时间 mm:ss），
//       支持搜索过滤、整行点击回跳播放（onPlaySentence）、左滑删除（removeFavorite）、空态引导，
//       以及右上角导出（exportFavoritesToText → 系统分享面板 / 复制到剪贴板）。
// 说明：纯 SwiftUI（仅导出用到 UIKit 的 UIActivityViewController 与 UIPasteboard），深色风格；
//       本页不自行套 NavigationStack，导航容器由宿主（学习页 / 播放页）提供。

import SwiftUI
import UIKit

// MARK: - 收藏句子列表

/// 收藏句子列表（StudyViewModel 为 @MainActor，整页标记 @MainActor 以便同步访问其状态）
@MainActor
public struct SentenceFavoritesView: View {

    // MARK: 输入

    /// 学习 ViewModel（收藏数据源与删除/导出能力）
    @ObservedObject private var viewModel: StudyViewModel
    /// 点击句子回调（参数为句子时间点，秒；无时间点时传 0）
    private let onPlaySentence: ((TimeInterval) -> Void)?

    public init(viewModel: StudyViewModel, onPlaySentence: ((TimeInterval) -> Void)? = nil) {
        self.viewModel = viewModel
        self.onPlaySentence = onPlaySentence
    }

    // MARK: 状态

    /// 搜索关键词
    @State private var searchText: String = ""
    /// 待分享的导出文本（非空时才允许弹出分享面板）
    @State private var exportedText: String?
    @State private var showShareSheet: Bool = false
    /// 轻量提示（宿主未注入 ToastCenter 时自建，避免强依赖环境对象）
    @State private var toastMessage: String?

    // MARK: 过滤结果

    /// 按关键词过滤后的收藏（匹配主字幕 / 译文 / 视频名，忽略大小写）
    private var displayedFavorites: [SentenceFavorite] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return viewModel.sentenceFavorites }
        return viewModel.sentenceFavorites.filter { favorite in
            favorite.primaryText.localizedCaseInsensitiveContains(keyword)
                || (favorite.secondaryText?.localizedCaseInsensitiveContains(keyword) ?? false)
                || (favorite.videoTitle?.localizedCaseInsensitiveContains(keyword) ?? false)
        }
    }

    // MARK: 主体

    public var body: some View {
        ZStack(alignment: .bottom) {
            content
            toastLayer
        }
        .background(Color.black.ignoresSafeArea())
        .searchable(text: $searchText, prompt: "搜索句子、译文或视频")
        .navigationTitle("收藏句子")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                exportMenu
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ActivityShareSheet(items: [exportedText ?? ""])
        }
    }

    /// 列表 / 空态
    @ViewBuilder
    private var content: some View {
        if viewModel.sentenceFavorites.isEmpty {
            emptyState
        } else {
            List {
                ForEach(displayedFavorites) { favorite in
                    FavoriteRow(favorite: favorite)
                        .listRowBackground(Palette.rowBackground)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onPlaySentence?(favorite.videoTime ?? 0)
                        }
                }
                .onDelete { indexSet in
                    for index in indexSet where displayedFavorites.indices.contains(index) {
                        viewModel.removeFavorite(displayedFavorites[index])
                    }
                    showToast("已取消收藏")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .overlay {
                // 有收藏但搜索无结果时的提示
                if displayedFavorites.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 32))
                            .foregroundColor(.gray)
                        Text("没有匹配的句子")
                            .foregroundColor(.gray)
                    }
                }
            }
        }
    }

    /// 空态引导
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 44))
                .foregroundColor(Palette.accent)
            Text("还没有收藏的句子")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
            Text("播放视频时长按字幕，即可收藏喜欢的句子")
                .font(.system(size: 13))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 导出

    /// 右上角导出菜单：复制为文本 / 系统分享
    private var exportMenu: some View {
        Menu {
            Button {
                copyToPasteboard()
            } label: {
                Label("复制为文本", systemImage: "doc.on.doc")
            }
            Button {
                exportAndShare()
            } label: {
                Label("分享…", systemImage: "square.and.arrow.up")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .foregroundColor(Palette.accent)
        }
        .disabled(viewModel.sentenceFavorites.isEmpty)
    }

    /// 生成导出文本并复制到剪贴板
    private func copyToPasteboard() {
        let text = viewModel.exportFavoritesToText()
        exportedText = text
        UIPasteboard.general.string = text
        showToast("已复制 \(viewModel.sentenceFavorites.count) 条收藏")
    }

    /// 生成导出文本并弹出系统分享面板
    private func exportAndShare() {
        exportedText = viewModel.exportFavoritesToText()
        showShareSheet = true
    }

    // MARK: 轻提示

    private var toastLayer: some View {
        Group {
            if let message = toastMessage {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Palette.accent))
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: toastMessage)
    }

    /// 显示轻提示并在 1.8 秒后自动消失
    private func showToast(_ message: String) {
        toastMessage = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if toastMessage == message { toastMessage = nil }
        }
    }
}

// MARK: - 收藏行

/// 单条收藏：主字幕（白 16pt）+ 次字幕（黄 14pt）+ 视频名 + 时间（灰）
private struct FavoriteRow: View {
    let favorite: SentenceFavorite

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(favorite.primaryText)
                .font(.system(size: 16))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)

            if let secondary = favorite.secondaryText, !secondary.isEmpty {
                Text(secondary)
                    .font(.system(size: 14))
                    .foregroundColor(Palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                if let title = favorite.videoTitle, !title.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "film")
                        Text(title).lineLimit(1)
                    }
                }
                if let time = favorite.videoTime {
                    HStack(spacing: 3) {
                        Image(systemName: "clock")
                        Text(FavoritesFormat.timestamp(time))
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .foregroundColor(.gray)
        }
        .padding(.vertical, 5)
    }
}

// MARK: - 系统分享面板

/// UIActivityViewController 的 SwiftUI 封装（用于分享导出的纯文本）
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - 配色与格式化

private enum Palette {
    /// 主色鹦鹉黄 #FFC107
    static let accent = Color(red: 1.0, green: 0.757, blue: 0.027)
    /// 列表行背景（深灰）
    static let rowBackground = Color(red: 0.11, green: 0.11, blue: 0.12)
}

private enum FavoritesFormat {
    /// 秒数格式化为 H:MM:SS / MM:SS（非法值归零）
    static func timestamp(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "00:00" }
        let total = Int(interval.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
