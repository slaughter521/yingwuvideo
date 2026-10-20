// 文件: WordBookView.swift — 生词本页面
// 职责：按来源视频分组展示生词本，支持搜索过滤（单词 / 释义）、左滑删除、点击查看详情。
// 契约：WordBookView(viewModel:onPlaySentence:)，viewModel 由 StudyView 传入以共享同一份数据；
//       onPlaySentence 逐级透传给 WordDetailSheet，用于点击原句时跳转到播放页对应时间点。

import SwiftUI

@MainActor
public struct WordBookView: View {

    // MARK: 入参

    /// 学习 ViewModel（由上层页面持有并共享）
    public var viewModel: StudyViewModel
    /// 播放指定时间点句子的回调（秒），由播放页经静态桥接或显式注入
    public var onPlaySentence: ((TimeInterval) -> Void)? = nil

    // MARK: 状态

    /// 搜索关键词（单词 / 释义 / 中文翻译）
    @State private var searchText = ""
    /// 当前查看详情的生词条目
    @State private var selectedEntry: WordEntry?
    /// 全局 Toast 提示中心
    @EnvironmentObject private var toast: ToastCenter

    // MARK: 视图主体

    public var body: some View {
        Group {
            if sections.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(sections, id: \.title) { section in
                        Section(section.title) {
                            ForEach(section.entries) { entry in
                                WordRow(entry: entry)
                                    .listRowBackground(StudyPalette.card)
                                    .listRowSeparatorTint(StudyPalette.stroke)
                                    .onTapGesture { selectedEntry = entry }
                            }
                            .onDelete { indexSet in
                                remove(at: indexSet, in: section)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(StudyPalette.background)
            }
        }
        .searchable(text: $searchText, prompt: "搜索单词或释义")
        .navigationTitle("生词本")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedEntry) { entry in
            WordDetailSheet(entry: entry, viewModel: viewModel, onPlaySentence: onPlaySentence)
        }
    }

    // MARK: 数据

    /// 按来源视频分组后的数据；未标注来源的条目归入「未标注来源」并排到最后
    private var sections: [(title: String, entries: [WordEntry])] {
        let source = filteredEntries
        let unknownTitle = "未标注来源"
        var groups: [String: [WordEntry]] = [:]
        var order: [String] = []
        for entry in source {
            // 空字符串同样视作未标注来源
            let title = (entry.sourceVideoTitle?.isEmpty == false) ? entry.sourceVideoTitle! : unknownTitle
            if groups[title] == nil {
                groups[title] = []
                order.append(title)
            }
            groups[title]?.append(entry)
        }
        return order
            // 「未标注来源」固定在最后，其余按标题升序
            .sorted { lhs, rhs in
                if lhs == unknownTitle { return false }
                if rhs == unknownTitle { return true }
                return lhs < rhs
            }
            .compactMap { title in
                guard let entries = groups[title], !entries.isEmpty else { return nil }
                return (title: title, entries: entries)
            }
    }

    /// 搜索过滤后的条目（空关键词时返回全部）
    private var filteredEntries: [WordEntry] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return viewModel.wordBook }
        return viewModel.wordBook.filter { entry in
            if entry.word.lowercased().contains(keyword) { return true }
            if entry.definition.lowercased().contains(keyword) { return true }
            if let translation = entry.translation, translation.lowercased().contains(keyword) { return true }
            return false
        }
    }

    // MARK: 操作

    /// 左滑删除：从 ViewModel 移除并提示
    private func remove(at indexSet: IndexSet, in section: (title: String, entries: [WordEntry])) {
        for index in indexSet where section.entries.indices.contains(index) {
            viewModel.removeWord(section.entries[index])
        }
        toast.show("已移出生词本")
    }

    // MARK: 空态

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 44))
                .foregroundStyle(StudyPalette.accent.opacity(0.8))
            Text("生词本是空的")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            Text("播放时点击字幕单词即可加入")
                .font(.system(size: 14))
                .foregroundStyle(StudyPalette.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudyPalette.background)
    }
}

// MARK: - 生词条行

/// 生词本列表行：单词（16pt semibold）+ 音标 + 中文释义 1 行 + 来源句 1 行灰字
@MainActor
private struct WordRow: View {
    let entry: WordEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.word)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                if let phonetic = entry.phonetic, !phonetic.isEmpty {
                    Text(phonetic)
                        .font(.system(size: 13))
                        .foregroundStyle(StudyPalette.accent)
                }
                Spacer(minLength: 0)
                if entry.reviewCount > 0 {
                    Text("复习 \(entry.reviewCount) 次")
                        .font(.system(size: 11))
                        .foregroundStyle(StudyPalette.secondaryText)
                }
            }

            Text(summaryText)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)

            if let sentence = entry.sourceSentence, !sentence.isEmpty {
                Text(sentence)
                    .font(.system(size: 12))
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    /// 释义摘要：优先中文释义，缺失时回退英文释义
    private var summaryText: String {
        if let translation = entry.translation, !translation.isEmpty { return translation }
        if !entry.definition.isEmpty { return entry.definition }
        return "暂无释义"
    }
}
