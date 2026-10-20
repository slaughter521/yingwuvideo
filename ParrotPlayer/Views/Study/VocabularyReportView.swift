// 文件: VocabularyReportView.swift — 词汇分析报告页
// 职责：展示 VocabularyReport 的汇总信息（视频标题 / 总词数）、各 VocabularyLevel 分级统计
//       （色块网格 + 纯 SwiftUI 横向条形图：条宽 = count / maxCount × 可用宽度 + 百分比标签）、
//       等级筛选 Picker（全部 + 各级），以及单词列表（单词 16pt + 等级胶囊 + 出现次数），
//       展开后显示该词出现的句子（用 WordOccurrence.cueIndices 从 track.cues 取文本），
//       点击句子回调 onPlaySentence(cue.startTime)；顶部提供「重新分析」按钮（onReanalyze 为 nil 时禁用）。
// 说明：纯 SwiftUI（图表为 GeometryReader + Capsule，无第三方依赖），深色风格；
//       track 为 nil 时退化显示「第 n 条字幕」。

import SwiftUI

// MARK: - 词汇报告页

/// 词汇分析报告页（标记为 @MainActor：宿主通常在主线程 push / 回调也在主线程触发）
@MainActor
public struct VocabularyReportView: View {

    // MARK: 输入

    /// 词汇分析报告
    private let report: VocabularyReport
    /// 关联字幕轨（用于还原单词出现的句子；nil 时只显示字幕序号）
    private let track: SubtitleTrack?
    /// 点击句子回调（参数为句子起始时间，秒）
    private let onPlaySentence: ((TimeInterval) -> Void)?
    /// 顶部「重新分析」回调（nil 时按钮禁用）
    private var onReanalyze: (() -> Void)?

    public init(report: VocabularyReport,
                track: SubtitleTrack? = nil,
                onPlaySentence: ((TimeInterval) -> Void)? = nil,
                onReanalyze: (() -> Void)? = nil) {
        self.report = report
        self.track = track
        self.onPlaySentence = onPlaySentence
        self.onReanalyze = onReanalyze
    }

    // MARK: 状态

    /// 等级筛选：全部 或某个 VocabularyLevel 的 rawValue（中文展示名）
    @State private var selectedLevel: String = LevelFilter.all.rawValue
    /// 当前展开的单词（同时只展开一个）
    @State private var expandedWordID: UUID?

    // MARK: 派生数据

    /// 各等级出现次数（按 VocabularyLevel.allCases 固定顺序展示，保证配色稳定）
    private var levelStats: [LevelStat] {
        VocabularyLevel.allCases.map { level in
            LevelStat(level: level, count: report.levelCounts[level] ?? 0)
        }
    }

    /// 条形图基准值（最大分级数量）
    private var maxCount: Int {
        levelStats.map { $0.count }.max() ?? 0
    }

    /// 分级数量之和（用于计算百分比）
    private var totalLevelCount: Int {
        levelStats.reduce(0) { $0 + $1.count }
    }

    /// 按等级筛选后的单词（同等级内按出现次数降序、词名字典序升序）
    private var displayedWords: [WordOccurrence] {
        let filtered: [WordOccurrence]
        if selectedLevel == LevelFilter.all.rawValue {
            filtered = report.wordDetails
        } else {
            filtered = report.wordDetails.filter { $0.level.rawValue == selectedLevel }
        }
        return filtered.sorted { lhs, rhs in
            lhs.count > rhs.count || (lhs.count == rhs.count && lhs.word < rhs.word)
        }
    }

    // MARK: 主体

    public var body: some View {
        List {
            summarySection
            levelSection
            filterSection
            wordSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("词汇报告")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: 汇总卡

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(report.videoTitle ?? "未知视频")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("去重后总词数 \(report.totalWords)")
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                    }
                    Spacer(minLength: 8)
                    Button {
                        onReanalyze?()
                    } label: {
                        Label("重新分析", systemImage: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(onReanalyze == nil
                                               ? Color.white.opacity(0.10)
                                               : Palette.accent.opacity(0.18))
                            )
                            .foregroundColor(onReanalyze == nil ? .gray : Palette.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(onReanalyze == nil)
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(Palette.rowBackground)
        }
    }

    // MARK: 分级统计

    private var levelSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                Text("分级统计")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.gray)

                // 色块网格：等级色点 + 名称 + 数量
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                    ForEach(levelStats) { stat in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(levelColor(stat.level))
                                .frame(width: 8, height: 8)
                            Text(stat.level.displayName)
                                .font(.system(size: 12))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text("\(stat.count)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.gray)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                    }
                }

                // 横向条形图：条宽 = count / maxCount × 可用宽度
                VStack(spacing: 8) {
                    ForEach(levelStats) { stat in
                        LevelBarRow(level: stat.level, count: stat.count, maxCount: maxCount, total: totalLevelCount)
                    }
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(Palette.rowBackground)
        }
    }

    // MARK: 等级筛选

    private var filterSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                Picker("等级筛选", selection: $selectedLevel) {
                    Text(LevelFilter.all.rawValue).tag(LevelFilter.all.rawValue)
                    ForEach(VocabularyLevel.allCases, id: \.rawValue) { level in
                        Text(level.displayName).tag(level.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }
            .listRowBackground(Palette.rowBackground)
            .onChange(of: selectedLevel) { _ in
                expandedWordID = nil   // 切换筛选时收起已展开项
            }
        } header: {
            Text("等级筛选")
        }
    }

    // MARK: 单词列表

    private var wordSection: some View {
        Section {
            if displayedWords.isEmpty {
                Text("该等级下没有单词")
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
                    .listRowBackground(Palette.rowBackground)
            } else {
                ForEach(displayedWords) { item in
                    DisclosureGroup(isExpanded: binding(for: item.id)) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(item.cueIndices.enumerated()), id: \.offset) { _, cueIndex in
                                sentenceRow(at: cueIndex)
                            }
                        }
                        .padding(.vertical, 6)
                    } label: {
                        HStack(spacing: 8) {
                            Text(item.word)
                                .font(.system(size: 16))
                                .foregroundColor(.white)
                            Text(item.level.displayName)
                                .font(.system(size: 11))
                                .foregroundColor(levelColor(item.level))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule().fill(levelColor(item.level).opacity(0.18))
                                )
                            Spacer(minLength: 0)
                            Text("×\(item.count)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.gray)
                        }
                    }
                    .listRowBackground(Palette.rowBackground)
                }
            }
        } header: {
            Text("单词（\(displayedWords.count)）")
        }
    }

    /// 单词出现的句子行：有字幕轨时显示原文（可点击回跳播放），否则只显示序号
    @ViewBuilder
    private func sentenceRow(at cueIndex: Int) -> some View {
        if let cue = Self.cue(at: cueIndex, in: track) {
            Button {
                onPlaySentence?(cue.startTime)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(cue.primaryText)
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    if let secondary = cue.secondaryText, !secondary.isEmpty {
                        Text(secondary)
                            .font(.system(size: 12))
                            .foregroundColor(Palette.accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        } else {
            Text("第 \(cueIndex + 1) 条字幕")
                .font(.system(size: 13))
                .foregroundColor(.gray)
        }
    }

    /// 展开状态绑定（同时只展开一个单词）
    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedWordID == id },
            set: { isExpanded in
                expandedWordID = isExpanded ? id : nil
            }
        )
    }

    // MARK: 工具

    /// 取指定索引的字幕（越界或无轨道时返回 nil）
    private static func cue(at index: Int, in track: SubtitleTrack?) -> SubtitleCue? {
        guard let track, index >= 0, index < track.cues.count else { return nil }
        return track.cues[index]
    }
}

// MARK: - 分级统计项

/// 单个等级的数量统计（用结构体而非元组，便于 ForEach 以 Identifiable 遍历）
private struct LevelStat: Identifiable {
    let level: VocabularyLevel
    let count: Int
    var id: String { level.rawValue }
}

// MARK: - 横向条形图行

/// 单个等级的条形图：等级名 + 条（宽 = count / maxCount × 可用宽度）+ 百分比标签
private struct LevelBarRow: View {
    let level: VocabularyLevel
    let count: Int
    let maxCount: Int
    let total: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(level.displayName)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .frame(width: 64, alignment: .leading)
                .lineLimit(1)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(levelColor(level))
                        .frame(width: max(3, proxy.size.width * ratio))
                }
            }
            .frame(height: 8)

            Text("\(percent)%")
                .font(.system(size: 11))
                .foregroundColor(.gray)
                .frame(width: 38, alignment: .trailing)
                .monospacedDigit()
        }
        .frame(height: 16)
    }

    /// 条宽比例（0...1）
    private var ratio: CGFloat {
        guard maxCount > 0 else { return 0 }
        return CGFloat(count) / CGFloat(maxCount)
    }

    /// 该等级占全部分级数量的百分比
    private var percent: Int {
        guard total > 0 else { return 0 }
        return Int((Double(count) / Double(total) * 100).rounded())
    }
}

// MARK: - 配色

private enum Palette {
    /// 主色鹦鹉黄 #FFC107
    static let accent = Color(red: 1.0, green: 0.757, blue: 0.027)
    /// 列表行背景（深灰）
    static let rowBackground = Color(red: 0.11, green: 0.11, blue: 0.12)
}

/// 筛选选项标识（与 Picker tag 保持一致）
private enum LevelFilter: String {
    case all = "全部"
}

/// 等级配色：cet4 绿 / cet6 蓝 / kaoyan 紫 / toefl 青 / ielts 橙 / rare 红 / unknown 灰
private func levelColor(_ level: VocabularyLevel) -> Color {
    switch level {
    case .cet4:    return Color(red: 0.30, green: 0.78, blue: 0.47)   // 绿
    case .cet6:    return Color(red: 0.36, green: 0.60, blue: 0.96)   // 蓝
    case .kaoyan:  return Color(red: 0.68, green: 0.48, blue: 0.94)   // 紫
    case .toefl:   return Color(red: 0.15, green: 0.78, blue: 0.85)   // 青
    case .ielts:   return Color(red: 1.00, green: 0.62, blue: 0.24)   // 橙
    case .rare:    return Color(red: 0.94, green: 0.35, blue: 0.36)   // 红
    case .unknown: return Color(red: 0.62, green: 0.62, blue: 0.64)   // 灰
    }
}
