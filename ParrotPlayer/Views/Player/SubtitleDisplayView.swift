// 文件: SubtitleDisplayView.swift — 字幕显示层：字幕渲染 + 点词查词浮层 + 字幕位置拖拽调整
// 说明：字幕文本由 SubtitleTextView 渲染（分词后每个单词可点击）；点词后弹出词卡
//       （本地词典优先，异步补充在线释义），可朗读、加入生词本、收藏整句。

import AVFoundation
import SwiftUI

public struct SubtitleDisplayView: View {

    // MARK: - 初始化

    public init(viewModel: PlayerViewModel,
                onAddWord: ((WordEntry) -> Void)? = nil,
                onAddSentence: ((SentenceFavorite) -> Void)? = nil,
                onPlaySentence: ((TimeInterval) -> Void)? = nil) {
        self.viewModel = viewModel
        self.onAddWord = onAddWord
        self.onAddSentence = onAddSentence
        self.onPlaySentence = onPlaySentence
    }

    @ObservedObject private var viewModel: PlayerViewModel
    private let onAddWord: ((WordEntry) -> Void)?
    private let onAddSentence: ((SentenceFavorite) -> Void)?
    private let onPlaySentence: ((TimeInterval) -> Void)?

    @EnvironmentObject private var settingsStore: AppSettingsStore

    /// 字幕纵向偏移（拖拽调整，持久化）
    @AppStorage("subtitleYOffset") private var yOffset: Double = 0

    @State private var selectedWord: String?
    @State private var definition: WordDefinition?
    @State private var isLoadingDefinition = false
    @State private var dragStart: CGFloat = 0

    // MARK: - 视图主体

    public var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            if viewModel.displayMode != .hidden {
                subtitleBlock
                    .offset(y: yOffset)
                    .gesture(dragGesture, including: .all)
                    .allowsHitTesting(viewModel.controlsVisible || selectedWord != nil)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 110)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(wordCardOverlay)
        .animation(.easeOut(duration: 0.2), value: viewModel.activeCue?.id)
    }

    // MARK: - 字幕块

    private var subtitleBlock: some View {
        VStack(spacing: 8) {
            SubtitleTextView(
                primaryText: viewModel.activeCue?.primaryText ?? "",
                secondaryText: viewModel.activeCue?.secondaryText,
                mode: viewModel.displayMode,
                fontSize: settingsStore.settings.subtitleFontSize
            ) { word, _ in
                handleWordTap(word)
            }
            .opacity(viewModel.activeCue == nil ? 0 : 1)

            // 控制条可见时显示快捷操作：收藏本句 / 上一句 / 下一句
            if viewModel.activeCue != nil && viewModel.controlsVisible && !viewModel.isLocked {
                HStack(spacing: 16) {
                    Button {
                        viewModel.playPreviousSentence()
                    } label: {
                        Image(systemName: "backward.frame.fill")
                    }
                    Button {
                        viewModel.repeatCurrentSentence()
                    } label: {
                        Image(systemName: "repeat")
                    }
                    Button {
                        viewModel.playNextSentence()
                    } label: {
                        Image(systemName: "forward.frame.fill")
                    }
                    if onAddSentence != nil {
                        Button {
                            favoriteCurrentSentence()
                        } label: {
                            Image(systemName: "heart")
                        }
                    }
                }
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.85))
                .transition(.opacity)
            }
        }
    }

    // MARK: - 点词查词

    private func handleWordTap(_ word: String) {
        let cleaned = word.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        guard !cleaned.isEmpty else { return }
        if settingsStore.settings.autoPauseOnWordTap { viewModel.pause() }
        selectedWord = cleaned
        definition = nil
        isLoadingDefinition = true

        Task {
            let service = DictionaryService()
            let local = service.lookup(cleaned)
            let online = try? await service.lookupOnline(cleaned)
            await MainActor.run {
                self.definition = online ?? local
                self.isLoadingDefinition = false
            }
        }
    }

    private func favoriteCurrentSentence() {
        guard let cue = viewModel.activeCue else { return }
        let favorite = SentenceFavorite(
            primaryText: cue.primaryText,
            secondaryText: cue.secondaryText,
            videoTitle: viewModel.currentItem?.title,
            videoTime: cue.startTime,
            dateAdded: Date()
        )
        onAddSentence?(favorite)
    }

    // MARK: - 词卡浮层

    private var wordCardOverlay: some View {
        Group {
            if let word = selectedWord {
                ZStack {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture { selectedWord = nil }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(word)
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(.white)
                            if let phonetic = definition?.phonetic {
                                Text(phonetic)
                                    .font(.system(size: 15))
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                            Spacer()
                            Button { SpeechSynthesizer.shared.speak(word) } label: {
                                Image(systemName: "speaker.wave.2.fill")
                                    .foregroundStyle(Color.parrotYellow)
                            }
                        }

                        if isLoadingDefinition {
                            ProgressView()
                                .tint(Color.parrotYellow)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else if let definition {
                            if let translation = definition.translation {
                                Text(translation)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(Color.parrotYellow)
                            }
                            ForEach(definition.definitions.prefix(3), id: \.self) { text in
                                Text("· \(text)")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                            if let example = definition.examples.first {
                                Text(example)
                                    .font(.system(size: 13, italic: true))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                        } else {
                            Text("暂无释义，可稍后重试")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.7))
                        }

                        if let cue = viewModel.activeCue {
                            Divider().background(.white.opacity(0.2))
                            Text(cue.primaryText)
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.65))
                                .lineLimit(2)
                                .onTapGesture {
                                    selectedWord = nil
                                    onPlaySentence?(cue.startTime)
                                }
                        }

                        HStack(spacing: 12) {
                            Button {
                                let entry = WordEntry(
                                    word: word,
                                    phonetic: definition?.phonetic,
                                    definition: definition?.definitions.first ?? "",
                                    translation: definition?.translation,
                                    sourceVideoTitle: viewModel.currentItem?.title,
                                    sourceSentence: viewModel.activeCue?.primaryText,
                                    dateAdded: Date()
                                )
                                onAddWord?(entry)
                                selectedWord = nil
                            } label: {
                                Text("加入生词本")
                                    .font(.system(size: 15, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color.parrotYellow)
                                    .foregroundStyle(.black)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            Button {
                                selectedWord = nil
                                viewModel.play()
                            } label: {
                                Text("继续播放")
                                    .font(.system(size: 15))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(.white.opacity(0.12))
                                    .foregroundStyle(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                    .padding(18)
                    .background(.ultraThinMaterial)
                    .background(Color.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(.white.opacity(0.15), lineWidth: 1)
                    )
                    .padding(.horizontal, 28)
                    .frame(maxWidth: .infinity)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
    }

    // MARK: - 拖拽调整字幕位置

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if dragStart == 0 { dragStart = yOffset }
                let next = dragStart + value.translation.height
                yOffset = min(max(next, -220), 120)
            }
            .onEnded { _ in dragStart = 0 }
    }
}

// MARK: - 语音朗读（单词发音）

/// 单词朗读器：AVSpeechSynthesizer 封装，英文单词用 en-US、语速偏慢便于听清
public final class SpeechSynthesizer: NSObject {
    public static let shared = SpeechSynthesizer()

    private let synthesizer = AVSpeechSynthesizer()

    private override init() { super.init() }

    public func speak(_ text: String, language: String = "en-US", rate: Float = 0.4) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        utterance.rate = rate
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        synthesizer.speak(utterance)
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
