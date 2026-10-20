// 文件: NotesView.swift — 学习笔记列表页（新建 / 编辑 / 删除）
// 职责：以 NavigationStack 承载 StudyViewModel.notes（最新在上），行内展示 2 行内容预览、
//       关联视频与相对时间；点击弹出编辑面板（TextEditor + 保存 updateNote / 删除 deleteNote / 取消），
//       右上角 + 弹出新建面板（保存走 addNote，来源视频回退 viewModel.currentVideoTitle）。
// 说明：纯 SwiftUI，深色风格；空态给出明确引导。

import SwiftUI

// MARK: - 笔记列表

/// 学习笔记列表（StudyViewModel 为 @MainActor，整页标记 @MainActor 以便同步访问其状态）
@MainActor
public struct NotesView: View {

    // MARK: 输入与状态

    @ObservedObject private var viewModel: StudyViewModel

    public init(viewModel: StudyViewModel) {
        self.viewModel = viewModel
    }

    /// 当前编辑的笔记（非 nil 时弹出编辑面板）
    @State private var editingNote: StudyNote?
    /// 是否弹出新建面板
    @State private var showNewNote: Bool = false
    /// 操作结果轻提示
    @State private var toastMessage: String?

    // MARK: 主体

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                content
                toastLayer
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("学习笔记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showNewNote = true
                    } label: {
                        Image(systemName: "plus")
                            .foregroundColor(Palette.accent)
                    }
                }
            }
            // 编辑已有笔记
            .sheet(item: $editingNote) { note in
                NoteEditorSheet(note: note, viewModel: viewModel) {
                    showToast("笔记已保存")
                }
            }
            // 新建笔记
            .sheet(isPresented: $showNewNote) {
                NoteComposerSheet(viewModel: viewModel) {
                    showToast("笔记已创建")
                }
            }
        }
    }

    /// 列表 / 空态
    @ViewBuilder
    private var content: some View {
        if viewModel.notes.isEmpty {
            emptyState
        } else {
            List {
                ForEach(viewModel.notes) { note in
                    Button {
                        editingNote = note
                    } label: {
                        NoteRow(note: note)
                    }
                    .listRowBackground(Palette.rowBackground)
                }
                .onDelete { indexSet in
                    for index in indexSet where viewModel.notes.indices.contains(index) {
                        viewModel.deleteNote(viewModel.notes[index])
                    }
                    showToast("笔记已删除")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
    }

    /// 空态引导
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "note.text")
                .font(.system(size: 44))
                .foregroundColor(Palette.accent)
            Text("还没有学习笔记")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
            Text("点击右上角 + ，记录单词用法、语法点或观影心得")
                .font(.system(size: 13))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func showToast(_ message: String) {
        toastMessage = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if toastMessage == message { toastMessage = nil }
        }
    }
}

// MARK: - 笔记行

/// 单条笔记：2 行内容预览 + 关联视频 + 相对时间
private struct NoteRow: View {
    let note: StudyNote

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note.content)
                .font(.system(size: 15))
                .foregroundColor(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            HStack(spacing: 10) {
                if let title = note.videoTitle, !title.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "film")
                        Text(title).lineLimit(1)
                    }
                }
                if let time = note.videoTime {
                    HStack(spacing: 3) {
                        Image(systemName: "clock")
                        Text(NotesFormat.timestamp(time))
                    }
                }
                Spacer(minLength: 0)
                // 相对时间（如「3 分钟前」），由 SwiftUI 自动刷新
                HStack(spacing: 2) {
                    Text("修改于")
                    Text(note.dateModified, style: .relative)
                }
                .lineLimit(1)
            }
            .font(.system(size: 12))
            .foregroundColor(.gray)
        }
        .padding(.vertical, 5)
    }
}

// MARK: - 编辑面板

/// 笔记编辑面板：TextEditor 草稿 + 保存 / 删除 / 取消
@MainActor
private struct NoteEditorSheet: View {
    let note: StudyNote
    @ObservedObject var viewModel: StudyViewModel
    /// 保存成功回调（用于宿主弹提示）
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var showDeleteConfirm: Bool = false

    init(note: StudyNote, viewModel: StudyViewModel, onSaved: @escaping () -> Void) {
        self.note = note
        self.viewModel = viewModel
        self.onSaved = onSaved
        // 以当前内容作为草稿初值，取消时不影响原始数据
        _draft = State(initialValue: note.content)
    }

    var body: some View {
        NavigationStack {
            editorContent
                .background(Color.black.ignoresSafeArea())
                .navigationTitle("编辑笔记")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { save() }
                            .disabled(trimmedDraft.isEmpty)
                    }
                }
                .confirmationDialog("删除后无法恢复", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                    Button("删除笔记", role: .destructive) {
                        viewModel.deleteNote(note)
                        dismiss()
                    }
                    Button("取消", role: .cancel) {}
                }
        }
    }

    @ViewBuilder
    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            metaInfo
            TextEditor(text: $draft)
                .font(.system(size: 16))
                .foregroundColor(.white)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Palette.rowBackground)
                )
                .frame(minHeight: 180)
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    /// 关联视频 / 关联句子等只读信息
    @ViewBuilder
    private var metaInfo: some View {
        if let title = note.videoTitle, !title.isEmpty {
            Label(title, systemImage: "film")
                .font(.system(size: 12))
                .foregroundColor(.gray)
        }
        if let sentence = note.sentenceText, !sentence.isEmpty {
            Text("关联句子：\(sentence)")
                .font(.system(size: 12))
                .foregroundColor(Palette.accent)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmedDraft.isEmpty else { return }
        var updated = note
        updated.content = trimmedDraft
        viewModel.updateNote(updated)
        onSaved()
        dismiss()
    }
}

// MARK: - 新建面板

/// 新建笔记面板：保存时来源视频回退为 viewModel.currentVideoTitle
@MainActor
private struct NoteComposerSheet: View {
    @ObservedObject var viewModel: StudyViewModel
    let onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if let title = viewModel.currentVideoTitle, !title.isEmpty {
                    Label("来源视频：\(title)", systemImage: "film")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                        .padding(.horizontal, 16)
                }
                TextEditor(text: $draft)
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Palette.rowBackground)
                    )
                    .frame(minHeight: 200)
                    .padding(.horizontal, 16)
                Spacer(minLength: 0)
            }
            .padding(.top, 16)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("新建笔记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(trimmedDraft.isEmpty)
                }
            }
        }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmedDraft.isEmpty else { return }
        viewModel.addNote(content: trimmedDraft,
                          videoTitle: viewModel.currentVideoTitle,
                          videoTime: nil,
                          sentenceText: nil)
        onCreated()
        dismiss()
    }
}

// MARK: - 配色与格式化

private enum Palette {
    /// 主色鹦鹉黄 #FFC107
    static let accent = Color(red: 1.0, green: 0.757, blue: 0.027)
    /// 列表行 / 输入框背景（深灰）
    static let rowBackground = Color(red: 0.11, green: 0.11, blue: 0.12)
}

private enum NotesFormat {
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
