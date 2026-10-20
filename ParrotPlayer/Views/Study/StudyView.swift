// 文件: StudyView.swift — 学习 Tab 根页面
// 职责：学习数据总览（生词本 / 收藏句子 / 笔记 / 跟读记录四项统计）、词汇分析报告入口、
//       功能导航列表（带数量角标）、以及学习数据导出（UIActivityViewController）。
// 契约：RootView 以无参 StudyView() 挂载，因此所有注入属性均带默认值，不得声明自定义 init
//       覆盖成员构造器。子页面共享本页的 @StateObject viewModel，保证数据一致。
// 播放注入：播放页无需修改本文件，通过 StudyPlaybackBridge 的静态闭包即可注入
//       onPlaySentence（句子时间点 → 全屏播放该句）与当前字幕轨。

import SwiftUI

// MARK: - 学习模块配色

/// 学习模块配色（深色：纯黑背景 + 鹦鹉黄 #FFC207 强调）
public enum StudyPalette {
    /// 主色：鹦鹉黄 #FFC207
    public static var accent: Color { Color(red: 1.0, green: 0.760, blue: 0.027) }
    /// 页面背景：纯黑
    public static var background: Color { Color.black }
    /// 卡片背景：深灰
    public static var card: Color { Color(red: 0.11, green: 0.11, blue: 0.12) }
    /// 分割线/描边
    public static var stroke: Color { Color.white.opacity(0.10) }
    /// 次要文字
    public static var secondaryText: Color { Color.white.opacity(0.55) }

    /// 词汇等级配色（与词汇报告页保持一致的语义色）
    public static func color(for level: VocabularyLevel) -> Color {
        switch level {
        case .cet4:    return .green
        case .cet6:    return .blue
        case .kaoyan:  return .orange
        case .toefl:   return .purple
        case .ielts:   return .pink
        case .rare:    return .red
        case .unknown: return .gray
        }
    }
}

// MARK: - 播放桥接

/// 播放页 → 学习页的注入桥接。
/// 目的：播放页要在「点击句子时全屏播放到该句」，但又不能修改本文件，故在此提供静态注入点。
/// 用法（播放页出现时写入，消失时置空）：
/// ```
/// StudyPlaybackBridge.playSentence = { [weak self] time in
///     self?.playlist = playlist; self?.fullScreenItem = video; self?.seek(to: time)  // 需全屏播放后再跳转
/// }
/// StudyPlaybackBridge.currentSubtitleTrack = { currentTrack }
/// ```
public enum StudyPlaybackBridge {
    /// 播放指定时间点的句子（参数为句子起始时间，秒）；调用方需先打开全屏播放页再 seek
    public static var playSentence: ((TimeInterval) -> Void)?
    /// 当前播放的字幕轨（供词汇报告页按 cue 索引定位句子，可选）
    public static var currentSubtitleTrack: (() -> SubtitleTrack?)?
}

// MARK: - 学习主页

@MainActor
public struct StudyView: View {

    // MARK: 状态

    @StateObject private var viewModel = StudyViewModel()
    /// 全局 Toast 提示中心（由 App 入口注入）
    @EnvironmentObject private var toast: ToastCenter

    /// 系统分享面板开关
    @State private var isExporting = false
    /// 本次导出的文本（生词本 + 收藏句子合并）
    @State private var exportText = ""

    // MARK: 外部注入（均可缺省，保证 StudyView() 契约）

    /// 点击句子时的播放回调（秒）；nil 时回退到 StudyPlaybackBridge.playSentence
    public var onPlaySentence: ((TimeInterval) -> Void)? = nil
    /// 当前字幕轨；nil 时回退到 StudyPlaybackBridge.currentSubtitleTrack
    public var subtitleTrack: SubtitleTrack? = nil

    // MARK: 视图主体

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statisticsCard
                    vocabularyCard
                    featureList
                    exportButton
                    if !hasAnyData {
                        emptyGuide
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollContentBackground(.hidden)
            .background(StudyPalette.background)
            .navigationTitle("学习")
            // 播放页写入的生词/收藏会落盘，学习页出现时重新载入以保持数据同步
            .onAppear { viewModel.reload() }
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $isExporting) {
                StudyActivityView(activityItems: [exportText]) {
                    toast.show("学习数据已导出")
                }
            }
            // ViewModel 的错误提示统一转交 Toast
            .onChange(of: viewModel.errorMessage) { message in
                if let message {
                    toast.show(message)
                    viewModel.errorMessage = nil
                }
            }
        }
    }

    // MARK: 顶部统计卡（4 格网格）

    private var statisticsCard: some View {
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            StudyStatCell(title: "生词本",
                          count: viewModel.wordBook.count,
                          badge: viewModel.todayCount > 0 ? "今日 +\(viewModel.todayCount)" : nil,
                          systemImage: "character.book.closed.fill")
            StudyStatCell(title: "收藏句子",
                          count: viewModel.sentenceFavorites.count,
                          badge: nil,
                          systemImage: "quote.bubble.fill")
            StudyStatCell(title: "笔记",
                          count: viewModel.notes.count,
                          badge: nil,
                          systemImage: "note.text")
            StudyStatCell(title: "跟读记录",
                          count: viewModel.shadowingRecords.count,
                          badge: nil,
                          systemImage: "waveform")
        }
    }

    // MARK: 词汇分析卡

    private var vocabularyCard: some View {
        StudySectionCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.doc.horizontal.fill")
                        .foregroundStyle(StudyPalette.accent)
                    Text("词汇分析")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer(minLength: 0)
                }

                if let report = viewModel.vocabularyReport {
                    NavigationLink {
                        VocabularyReportView(report: report,
                                             track: resolvedTrack,
                                             onPlaySentence: resolvedPlaySentence)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(report.videoTitle?.isEmpty == false ? (report.videoTitle ?? "") : "未命名视频")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text("去重词数 \(report.totalWords)")
                                .font(.system(size: 13))
                                .foregroundStyle(StudyPalette.secondaryText)
                            levelSummary(report)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("播放带字幕的视频后可生成词汇分析")
                            .font(.system(size: 14))
                            .foregroundStyle(StudyPalette.secondaryText)
                        Text("在播放页点击字幕中的单词即可加入生词本")
                            .font(.system(size: 12))
                            .foregroundStyle(StudyPalette.secondaryText)
                    }
                }
            }
        }
    }

    /// 各等级小圆点 + 数量摘要
    @ViewBuilder
    private func levelSummary(_ report: VocabularyReport) -> some View {
        let items = VocabularyLevel.allCases.filter { (report.levelCounts[$0] ?? 0) > 0 }
        if items.isEmpty {
            Text("暂无分级数据")
                .font(.system(size: 12))
                .foregroundStyle(StudyPalette.secondaryText)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), alignment: .leading)], spacing: 8) {
                ForEach(items, id: \.self) { level in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(StudyPalette.color(for: level))
                            .frame(width: 8, height: 8)
                        Text("\(level.displayName) \(report.levelCounts[level] ?? 0)")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
        }
    }

    // MARK: 功能导航列表

    private var featureList: some View {
        StudySectionCard {
            VStack(spacing: 0) {
                StudyFeatureRow(icon: "character.book.closed.fill",
                                title: "生词本",
                                badge: viewModel.wordBook.count) {
                    WordBookView(viewModel: viewModel, onPlaySentence: resolvedPlaySentence)
                }
                Divider().background(StudyPalette.stroke)
                StudyFeatureRow(icon: "quote.bubble.fill",
                                title: "收藏句子",
                                badge: viewModel.sentenceFavorites.count) {
                    SentenceFavoritesView(viewModel: viewModel, onPlaySentence: resolvedPlaySentence)
                }
                Divider().background(StudyPalette.stroke)
                StudyFeatureRow(icon: "note.text",
                                title: "笔记",
                                badge: viewModel.notes.count) {
                    // NotesView 由笔记模块提供，公开构造器仅接收 viewModel
                    NotesView(viewModel: viewModel)
                }
                Divider().background(StudyPalette.stroke)
                StudyFeatureRow(icon: "waveform",
                                title: "跟读练习",
                                badge: viewModel.shadowingRecords.count) {
                    ShadowingPracticeView(viewModel: viewModel, onPlaySentence: resolvedPlaySentence)
                }
            }
        }
    }

    // MARK: 导出按钮

    private var exportButton: some View {
        Button {
            exportText = viewModel.exportWordBookToText() + "\n\n" + viewModel.exportFavoritesToText()
            isExporting = true
        } label: {
            Label("导出学习数据", systemImage: "square.and.arrow.up")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(StudyPalette.accent)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!hasAnyData)
        .opacity(hasAnyData ? 1 : 0.45)
    }

    // MARK: 空态引导

    private var emptyGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("开始你的学习之旅", systemImage: "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(StudyPalette.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text("1. 打开带字幕的视频，点击字幕里的单词加入生词本")
                Text("2. 长按或收藏常用句子，方便复习与跟读")
                Text("3. 播放页分析词汇后，可在这里查看词汇报告")
            }
            .font(.system(size: 13))
            .foregroundStyle(StudyPalette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(StudyPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: 派生值

    /// 是否存在任意学习数据（决定空态与导出可用性）
    private var hasAnyData: Bool {
        !viewModel.wordBook.isEmpty
            || !viewModel.sentenceFavorites.isEmpty
            || !viewModel.notes.isEmpty
            || !viewModel.shadowingRecords.isEmpty
    }

    /// 播放回调：优先外部传入，其次静态桥接
    private var resolvedPlaySentence: ((TimeInterval) -> Void)? {
        onPlaySentence ?? StudyPlaybackBridge.playSentence
    }

    /// 当前字幕轨：优先外部传入，其次静态桥接
    private var resolvedTrack: SubtitleTrack? {
        subtitleTrack ?? StudyPlaybackBridge.currentSubtitleTrack?()
    }
}

// MARK: - 统计格子

/// 顶部统计卡单格：图标 + 数量 + 标题 + 可选角标
@MainActor
private struct StudyStatCell: View {
    let title: String
    let count: Int
    let badge: String?
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 14))
                    .foregroundStyle(StudyPalette.accent)
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(.system(size: 10))
                        .foregroundStyle(StudyPalette.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(StudyPalette.accent.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            Text("\(count)")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(StudyPalette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(StudyPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - 通用分区卡容器

/// 分区卡片容器：深灰圆角底 + 统一内边距，承载各类内容
@MainActor
private struct StudySectionCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StudyPalette.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - 功能导航行

/// 功能导航行（NavigationLink 包裹）：左侧图标 + 标题，右侧数量角标 + 箭头
@MainActor
private struct StudyFeatureRow<Destination: View>: View {
    let icon: String
    let title: String
    let badge: Int
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(StudyPalette.accent)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(StudyPalette.accent)
                        .clipShape(Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StudyPalette.secondaryText)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 系统分享面板

/// UIActivityViewController 的 SwiftUI 封装，用于导出学习数据文本
public struct StudyActivityView: UIViewControllerRepresentable {
    /// 要分享的内容（本模块为合并后的纯文本）
    public let activityItems: [Any]
    /// 分享完成回调（仅成功时触发，主线程）
    public let onCompleted: (() -> Void)?

    public init(activityItems: [Any], onCompleted: (() -> Void)? = nil) {
        self.activityItems = activityItems
        self.onCompleted = onCompleted
    }

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, error in
            if completed {
                DispatchQueue.main.async { onCompleted?() }
            } else if let error {
                print("[StudyActivityView] 导出取消或失败：\(error.localizedDescription)")
            }
        }
        return controller
    }

    public func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // 内容在创建时确定，无需更新
    }
}
