// 文件: WordDetailSheet.swift — 生词详情半屏浮层
// 职责：展示单个 WordEntry 的完整信息（单词大字 + 音标 + 发音按钮、英文释义、中文释义、
//       例句 / 原句、来源视频、复习次数），支持点击原句跳转播放、destructive 的「移出生词本」。
// 契约：WordDetailSheet(entry:viewModel:onPlaySentence:)，由 WordBookView 以 sheet(item:) 呈现；
//       onPlaySentence 为 nil 时原句行灰显并提示不可跳转。
// 说明：WordEntry 使用其在 StudyModels.swift 中的成员构造器，字段顺序为
//       id, word, phonetic, definition, translation, sourceVideoTitle, sourceSentence, dateAdded, reviewCount。

import SwiftUI
import AVFoundation

// MARK: - 发音器

/// 英语单词发音器：封装 AVSpeechSynthesizer（en-US，语速 0.8）。
/// 未标注 @MainActor：AVSpeechSynthesizerDelegate 由系统后台线程回调，
/// 因此回调内显式切回主线程再更新 @Published 状态。
public final class WordSpeaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    /// 是否正在朗读
    @Published public private(set) var isSpeaking: Bool = false

    private let synthesizer = AVSpeechSynthesizer()

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    deinit {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    /// 朗读文本；正在朗读时再次调用会停止（切换式）
    /// - Parameter text: 要朗读的单词或句子
    public func speak(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            updateSpeaking(false)
            return
        }

        // 朗读前把音频会话切换到播放类别，保证静音键开启时也能出声
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.8
        updateSpeaking(true)
        synthesizer.speak(utterance)
    }

    /// 停止朗读
    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        updateSpeaking(false)
    }

    private func updateSpeaking(_ value: Bool) {
        if Thread.isMainThread {
            isSpeaking = value
        } else {
            DispatchQueue.main.async { self.isSpeaking = value }
        }
    }

    // MARK: AVSpeechSynthesizerDelegate

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        updateSpeaking(false)
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        updateSpeaking(false)
    }
}

// MARK: - 详情浮层

@MainActor
public struct WordDetailSheet: View {

    // MARK: 入参

    /// 当前展示的生词条目
    public var entry: WordEntry
    /// 学习 ViewModel（由上层共享，用于移出生词本）
    public var viewModel: StudyViewModel
    /// 播放原句回调（秒）；nil 时原句行灰显
    public var onPlaySentence: ((TimeInterval) -> Void)? = nil

    // MARK: 状态

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var toast: ToastCenter
    @StateObject private var speaker = WordSpeaker()

    // MARK: 视图主体

    public var body: some View {
        VStack(spacing: 0) {
            dragIndicator
            headerArea
            Divider()
                .background(StudyPalette.stroke)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DetailInfoSection(title: "英文释义") {
                        Text(entry.definition.isEmpty ? "暂无英文释义" : entry.definition)
                            .font(.system(size: 15))
                            .foregroundStyle(entry.definition.isEmpty ? StudyPalette.secondaryText : .white.opacity(0.9))
                    }

                    DetailInfoSection(title: "中文释义") {
                        Text(translationText)
                            .font(.system(size: 15))
                            .foregroundStyle(hasTranslation ? .white : StudyPalette.secondaryText)
                    }

                    if let sentence = entry.sourceSentence, !sentence.isEmpty {
                        DetailInfoSection(title: "例句") {
                            sentenceRow(sentence)
                        }
                    }

                    DetailInfoSection(title: "来源视频") {
                        Text(entry.sourceVideoTitle?.isEmpty == false ? entry.sourceVideoTitle! : "未标注来源")
                            .font(.system(size: 15))
                            .foregroundStyle(entry.sourceVideoTitle?.isEmpty == false ? .white : StudyPalette.secondaryText)
                    }

                    metaRow
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            Divider()
                .background(StudyPalette.stroke)
            removeButton
        }
        .background(StudyPalette.background.ignoresSafeArea())
    }

    // MARK: 顶部：drag indicator

    private var dragIndicator: some View {
        Capsule()
            .fill(Color.white.opacity(0.25))
            .frame(width: 36, height: 5)
            .padding(.top, 8)
            .padding(.bottom, 10)
    }

    // MARK: 顶部：单词 + 音标 + 发音 + 关闭

    private var headerArea: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.word)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                HStack(spacing: 14) {
                    if let phonetic = entry.phonetic, !phonetic.isEmpty {
                        Text(phonetic)
                            .font(.system(size: 15))
                            .foregroundStyle(StudyPalette.accent)
                    }
                    Button {
                        speaker.speak(entry.word)
                    } label: {
                        Image(systemName: speaker.isSpeaking ? "stop.circle.fill" : "speaker.wave.2.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(StudyPalette.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("朗读单词"))
                }
            }
            Spacer(minLength: 0)
            closeButton
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private var closeButton: some View {
        Button {
            speaker.stop()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.12))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("关闭"))
    }

    // MARK: 例句行（可点击跳转播放）

    /// 原句行：注入了播放回调时可点击整行跳转播放；未注入时灰显提示不可跳播
    private func sentenceRow(_ sentence: String) -> some View {
        Group {
            if let onPlaySentence {
                Button {
                    speaker.stop()
                    dismiss()
                    // WordEntry 未记录句子时间点（模型字段不可改动），这里以 0 作为起点传入：
                    // 播放页收到回调后应先打开全屏播放再 seek（无可定位时间时从视频起点/当前进度播放）
                    onPlaySentence(0)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(StudyPalette.accent)
                        Text(sentence)
                            .font(.system(size: 15))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(sentence)
                        .font(.system(size: 15))
                        .foregroundStyle(StudyPalette.secondaryText)
                    Text("（未连接播放器，无法跳转原句）")
                        .font(.system(size: 12))
                        .foregroundStyle(StudyPalette.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: 元信息

    private var metaRow: some View {
        HStack(spacing: 18) {
            Label("加入于 \(formattedDate)", systemImage: "calendar")
            Label("复习 \(entry.reviewCount) 次", systemImage: "arrow.triangle.2.circlepath")
        }
        .font(.system(size: 12))
        .foregroundStyle(StudyPalette.secondaryText)
    }

    // MARK: 底部删除按钮

    private var removeButton: some View {
        Button(role: .destructive) {
            speaker.stop()
            viewModel.removeWord(entry)
            toast.show("已移出生词本")
            dismiss()
        } label: {
            Text("移出生词本")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.red.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: 派生值

    private var hasTranslation: Bool {
        guard let translation = entry.translation else { return false }
        return !translation.isEmpty
    }

    private var translationText: String {
        hasTranslation ? entry.translation! : "暂无中文释义"
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: entry.dateAdded)
    }
}

// MARK: - 分区容器

/// 详情分区：鹦鹉黄小标题 + 内容，统一间距
@MainActor
private struct DetailInfoSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(StudyPalette.accent)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
