// 文件: ShadowingPracticeView.swift — 跟读练习页（句子列表 + 单句练习 + 评分 + 历史记录）
// 职责：无字幕轨时给出空态引导；有字幕轨时列出句子（编号 + 主字幕 + 次字幕小字），
//       进入单句练习后可「播放原声」（AVPlayer seek 到 cue.startTime，周期时间观察器到 cue.endTime 自动停）、
//       ShadowingRecorder 录音（录音中显示随机动画波形）、ShadowingPlayer 回放录音、
//       ShadowingScorer 评分（圆环 + 评语）并写入 StudyViewModel.addShadowingRecord。
// 说明：录音/播放对象由练习页持有，离开页面统一 stop 释放；麦克风未授权时给出「前往设置」引导。
//       实际调用的跟读 API（均位于 StudyViewModel+Shadowing.swift，类均为 @MainActor）：
//       - ShadowingScorer.score(originalDuration:recordDuration:originalVolumeEnvelope:recordVolumeEnvelope:) -> Int
//       - ShadowingRecorder：start() throws / stop() -> URL? / deleteCurrentRecording() /
//                            requestPermissionIfNeeded() async -> Bool / isRecording
//       - ShadowingRecorder.extractVolumeEnvelope(from:) async -> [Float]（nonisolated static）
//       - ShadowingPlayer：play(url:) / stop()

import SwiftUI
import AVFoundation
import UIKit

// MARK: - 跟读练习主页

/// 跟读练习主页（句子列表 + 跟读历史）。整页标记 @MainActor：
/// StudyViewModel 与跟读类均为 @MainActor，页面成员直接同步访问其状态。
@MainActor
public struct ShadowingPracticeView: View {

    // MARK: 输入

    @ObservedObject private var viewModel: StudyViewModel
    /// 当前视频地址（存在时才能播放原声片段）
    private let videoURL: URL?
    /// 字幕轨（nil 或空时显示空态引导）
    private let track: SubtitleTrack?
    /// 点击句子时的播放回调（由学习页注入）
    private let onPlaySentence: ((TimeInterval) -> Void)?

    public init(viewModel: StudyViewModel, videoURL: URL? = nil, track: SubtitleTrack? = nil) {
        self.viewModel = viewModel
        self.videoURL = videoURL
        self.track = track
        self.onPlaySentence = nil
    }

    /// 便利构造：学习页以（viewModel, onPlaySentence）调用；视频与字幕轨待上下文注入
    public init(viewModel: StudyViewModel, onPlaySentence: ((TimeInterval) -> Void)? = nil) {
        self.viewModel = viewModel
        self.videoURL = nil
        self.track = nil
        self.onPlaySentence = onPlaySentence
    }

    // MARK: 状态

    @State private var showClearConfirm: Bool = false
    @State private var toastMessage: String?

    // MARK: 派生数据

    private var cues: [SubtitleCue] { track?.cues ?? [] }

    // MARK: 主体

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                content
                    .background(Color.black.ignoresSafeArea())
                toastLayer
            }
            .navigationTitle("跟读练习")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("清空全部跟读记录？删除后无法恢复。",
                                isPresented: $showClearConfirm,
                                titleVisibility: .visible) {
                Button("清空记录", role: .destructive) {
                    Task { await clearAllRecords() }
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if cues.isEmpty {
            emptyState
        } else {
            List {
                Section {
                    ForEach(Array(cues.enumerated()), id: \.element.id) { index, cue in
                        NavigationLink {
                            SentencePracticeView(viewModel: viewModel,
                                                 index: index,
                                                 cue: cue,
                                                 videoURL: videoURL)
                        } label: {
                            SentenceRow(index: index, cue: cue)
                        }
                        .listRowBackground(Palette.rowBackground)
                    }
                } header: {
                    Text("选择句子练习（共 \(cues.count) 句）")
                }

                Section {
                    if viewModel.shadowingRecords.isEmpty {
                        Text("还没有跟读记录，完成后会自动保存")
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                            .listRowBackground(Palette.rowBackground)
                    } else {
                        ForEach(viewModel.shadowingRecords) { record in
                            HistoryRow(record: record)
                                .listRowBackground(Palette.rowBackground)
                        }
                        .onDelete { indexSet in
                            Task {
                                for index in indexSet where viewModel.shadowingRecords.indices.contains(index) {
                                    await deleteRecord(viewModel.shadowingRecords[index])
                                }
                                showToast("已删除记录")
                            }
                        }
                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Text("清空记录")
                        }
                        .listRowBackground(Palette.rowBackground)
                    }
                } header: {
                    Text("跟读历史（\(viewModel.shadowingRecords.count)）")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
    }

    /// 空态引导
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.and.signal.meter")
                .font(.system(size: 44))
                .foregroundColor(Palette.accent)
            Text("请先播放带字幕的视频，再进入跟读练习")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            Text("进入播放页载入字幕后，本页会自动列出可练习的句子")
                .font(.system(size: 13))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 历史记录操作

    /// 清空全部跟读记录（ViewModel 会一并删除录音文件）
    private func clearAllRecords() async {
        viewModel.clearShadowingRecords()
        showToast("已清空跟读记录")
    }

    /// 删除单条记录：
    /// StudyViewModel 只提供 clearShadowingRecords()，因此先将其余记录的录音文件迁移到新路径
    /// （避免被整体清空时一并删除），再清空并回写，保证界面与磁盘一致。
    private func deleteRecord(_ record: ShadowingRecord) async {
        let all = viewModel.shadowingRecords
        guard all.contains(where: { $0.id == record.id }) else { return }
        guard all.count > 1 else {
            viewModel.clearShadowingRecords()
            return
        }

        var kept: [ShadowingRecord] = []
        for item in all where item.id != record.id {
            var keptItem = item
            if let path = item.audioPath, FileManager.default.fileExists(atPath: path) {
                let source = URL(fileURLWithPath: path)
                let target = source.deletingLastPathComponent()
                    .appendingPathComponent(UUID().uuidString + ".m4a")
                if (try? FileManager.default.moveItem(at: source, to: target)) != nil {
                    keptItem.audioPath = target.path
                }
            }
            kept.append(keptItem)
        }

        viewModel.clearShadowingRecords()
        // addShadowingRecord 插入在最前，倒序回写可保持原有顺序
        for item in kept.reversed() {
            viewModel.addShadowingRecord(item)
        }
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

// MARK: - 句子行 / 历史行

/// 句子列表行：编号 + 主字幕 + 次字幕（小字）
private struct SentenceRow: View {
    let index: Int
    let cue: SubtitleCue

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.black)
                .frame(width: 26, height: 20)
                .background(Capsule().fill(Palette.accent))
            VStack(alignment: .leading, spacing: 3) {
                Text(cue.primaryText)
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
                if let secondary = cue.secondaryText, !secondary.isEmpty {
                    Text(secondary)
                        .font(.system(size: 12))
                        .foregroundColor(Palette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// 历史记录行：句子 + 分数（色标）+ 日期
private struct HistoryRow: View {
    let record: ShadowingRecord

    var body: some View {
        HStack(spacing: 10) {
            Text(record.sentence)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("\(record.score)")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(scoreColor(record.score))
                .frame(width: 34, alignment: .trailing)
            Text(record.dateCreated, style: .date)
                .font(.system(size: 11))
                .foregroundColor(.gray)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - 单句练习页

/// 单句跟读练习：播放原声 → 录音 → 回放 → 评分保存
@MainActor
private struct SentencePracticeView: View {

    // MARK: 输入

    @ObservedObject var viewModel: StudyViewModel
    /// 句子序号（仅用于标题展示）
    let index: Int
    /// 当前练习的字幕
    let cue: SubtitleCue
    /// 视频地址（nil 时无法播放原声）
    let videoURL: URL?

    // MARK: 音频对象（生命周期由本页持有）

    @StateObject private var recorder = ShadowingRecorder()
    @StateObject private var playback = ShadowingPlayer()
    @StateObject private var cuePlayer = SentenceAudioPlayer()

    // MARK: 状态

    /// 本次录音文件地址
    @State private var recordingURL: URL?
    /// 录音时长（秒）
    @State private var recordDuration: TimeInterval = 0
    /// 评分结果（nil 表示未评分）
    @State private var score: Int?
    @State private var isScoring: Bool = false
    /// 麦克风未授权
    @State private var permissionDenied: Bool = false
    /// 操作提示 / 错误提示
    @State private var message: String?
    /// 评分是否已写入历史
    @State private var didSave: Bool = false

    // MARK: 主体

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sentenceCard
                if permissionDenied { permissionBanner }
                controlCard
                if let score { resultCard(score: score) }
                if let message {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
            }
            .padding(16)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("第 \(index + 1) 句")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            Task { await stopAll() }
        }
    }

    /// 当前句原文卡（主字幕大字 + 次字幕）
    private var sentenceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(cue.primaryText)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
            if let secondary = cue.secondaryText, !secondary.isEmpty {
                Text(secondary)
                    .font(.system(size: 16))
                    .foregroundColor(Palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("原句时长 \(String(format: "%.1f", max(cue.endTime - cue.startTime, 0))) 秒")
                .font(.system(size: 12))
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Palette.rowBackground)
        )
    }

    /// 麦克风权限引导
    private var permissionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.slash.fill")
                .foregroundColor(Palette.warning)
            Text("请在设置中允许麦克风权限")
                .font(.system(size: 13))
                .foregroundColor(.white)
            Spacer(minLength: 0)
            Button("前往设置") {
                openSettings()
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Palette.accent)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.warning.opacity(0.16))
        )
    }

    /// 控制区：播放原声 / 录音 / 回放 / 重录 / 完成评分
    private var controlCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                actionButton(
                    title: cuePlayer.isPlaying ? "停止原声" : "播放原声",
                    systemImage: cuePlayer.isPlaying ? "stop.fill" : "speaker.wave.2.fill",
                    enabled: videoURL != nil || cuePlayer.isPlaying,
                    highlighted: cuePlayer.isPlaying
                ) {
                    toggleOriginalPlayback()
                }

                actionButton(
                    title: recorder.isRecording ? "停止录音" : (recordingURL == nil ? "开始录音" : "重新录音"),
                    systemImage: recorder.isRecording ? "stop.fill" : "mic.fill",
                    enabled: true,
                    highlighted: recorder.isRecording
                ) {
                    Task { await toggleRecording() }
                }
            }

            if recorder.isRecording {
                RecordingWaveView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let url = recordingURL, !recorder.isRecording {
                HStack(spacing: 12) {
                    actionButton(title: "播放我的录音", systemImage: "play.fill", enabled: true, highlighted: false) {
                        playback.play(url: url)
                    }
                    actionButton(title: "重录", systemImage: "arrow.counterclockwise", enabled: true, highlighted: false) {
                        Task { await retake() }
                    }
                }
                HStack {
                    Text("录音时长 \(String(format: "%.1f", recordDuration)) 秒")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                    Spacer(minLength: 8)
                    Button {
                        Task { await finishScoring() }
                    } label: {
                        HStack(spacing: 6) {
                            if isScoring { ProgressView().tint(.black) }
                            Text(isScoring ? "评分中…" : (didSave ? "已保存，重新评分" : "完成评分"))
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Palette.accent))
                    }
                    .disabled(isScoring)
                }
            } else if videoURL == nil {
                Text("未提供视频地址，无法播放原声，可先录音练习")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }
        }
    }

    /// 评分结果卡：圆环 + 评语
    private func resultCard(score: Int) -> some View {
        HStack(spacing: 16) {
            ScoreRingView(score: score)
            VStack(alignment: .leading, spacing: 6) {
                Text(comment(for: score))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(scoreColor(score))
                    .fixedSize(horizontal: false, vertical: true)
                Text(didSave ? "已保存到跟读历史" : "评分完成")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Palette.rowBackground)
        )
    }

    // MARK: 操作

    /// 播放 / 停止原声片段（seek 到 cue.startTime，到 cue.endTime 自动停）
    private func toggleOriginalPlayback() {
        if cuePlayer.isPlaying {
            cuePlayer.stop()
            return
        }
        guard let videoURL else {
            message = "未提供视频地址，无法播放原声"
            return
        }
        cuePlayer.play(url: videoURL, start: cue.startTime, end: cue.endTime)
    }

    /// 开始 / 停止录音；开始前先确保麦克风权限
    private func toggleRecording() async {
        if recorder.isRecording {
            guard let url = recorder.stop() else {
                message = "录音失败，请重试"
                return
            }
            recordingURL = url
            recordDuration = Self.duration(of: url)
            score = nil
            didSave = false
            message = "录音完成，可试听或完成评分"
            return
        }

        let granted = await recorder.requestPermissionIfNeeded()
        guard granted else {
            permissionDenied = true
            message = "未获得麦克风权限，无法录音"
            return
        }
        permissionDenied = false
        do {
            try recorder.start()
            recordingURL = nil
            recordDuration = 0
            score = nil
            didSave = false
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    /// 重录：删除当前录音并复位状态
    private func retake() async {
        playback.stop()
        recorder.deleteCurrentRecording()
        recordingURL = nil
        recordDuration = 0
        score = nil
        didSave = false
        message = nil
    }

    /// 完成评分：提取包络 → ShadowingScorer 评分 → 写入 ViewModel
    private func finishScoring() async {
        guard let url = recordingURL else { return }
        isScoring = true
        defer { isScoring = false }

        playback.stop()

        // 录音音量包络
        let recordEnvelope = await ShadowingRecorder.extractVolumeEnvelope(from: url)
        // 原声音量包络：直接尝试从视频文件解码（视频容器不可解码时返回空数组，评分器已做兜底）
        var originalEnvelope: [Float] = []
        if let videoURL {
            originalEnvelope = await ShadowingRecorder.extractVolumeEnvelope(from: videoURL)
        }

        let value = ShadowingScorer.score(
            originalDuration: max(cue.endTime - cue.startTime, 0),
            recordDuration: recordDuration,
            originalVolumeEnvelope: originalEnvelope,
            recordVolumeEnvelope: recordEnvelope
        )
        score = value

        let record = ShadowingRecord(id: UUID(),
                                     sentence: cue.primaryText,
                                     score: value,
                                     audioPath: url.path,
                                     dateCreated: Date())
        viewModel.addShadowingRecord(record)
        didSave = true
        message = "评分 \(value) 分，已保存到跟读历史"
    }

    /// 离开页面时统一停止录音与播放，释放音频会话
    private func stopAll() async {
        if recorder.isRecording {
            _ = recorder.stop()
        }
        playback.stop()
        cuePlayer.stop()
    }

    /// 打开系统设置（用于开启麦克风权限）
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        Task { @MainActor in
            await UIApplication.shared.open(url)
        }
    }

    /// 读取录音文件时长（秒）
    private static func duration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return 0 }
        return Double(file.length) / rate
    }

    /// 评分评语
    private func comment(for score: Int) -> String {
        switch score {
        case 90...:   return "优秀！语调很接近"
        case 75...:   return "良好，注意连读"
        case 60...:   return "及格，再练几遍"
        default:      return "继续加油"
        }
    }

    /// 通用操作按钮
    private func actionButton(title: String,
                              systemImage: String,
                              enabled: Bool,
                              highlighted: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(highlighted ? Palette.accent : Color.white.opacity(0.10))
                )
                .foregroundColor(highlighted ? .black : (enabled ? .white : .gray))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - 原声片段播放器

/// 播放视频中 [start, end) 区间的原声：seek 到起点后播放，
/// 通过 addPeriodicTimeObserver 每 0.1 秒判断是否到达终点，到点自动暂停并移除观察器。
/// 说明：该类不做 MainActor 隔离，时间观察器回调统一派发到主队列，deinit 中可安全释放。
private final class SentenceAudioPlayer: ObservableObject {

    @Published private(set) var isPlaying: Bool = false

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endTime: TimeInterval = 0

    /// 播放片段
    func play(url: URL, start: TimeInterval, end: TimeInterval) {
        stop()
        let player = AVPlayer(url: url)
        self.player = player
        // 至少留出 0.2 秒，避免异常时间戳导致立即停止
        self.endTime = max(end, start + 0.2)
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero)
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            if time.seconds >= self.endTime {
                self.stop()
            }
        }
        player.play()
        isPlaying = true
    }

    /// 停止播放并移除观察器
    func stop() {
        if let observer = timeObserver, let player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
    }

    deinit { stop() }
}

// MARK: - 录音波形动画

/// 录音中的波形动画：若干 Capsule 高度随机变化（0.16 秒一跳）
private struct RecordingWaveView: View {
    @State private var heights: [CGFloat] = [0.35, 0.7, 0.45, 0.9, 0.5, 0.75, 0.4]
    private let timer = Timer.publish(every: 0.16, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(0..<heights.count, id: \.self) { index in
                Capsule()
                    .fill(Palette.accent)
                    .frame(width: 4, height: 6 + 26 * heights[index])
            }
        }
        .frame(height: 34)
        .onReceive(timer) { _ in
            heights = heights.map { _ in CGFloat.random(in: 0.15...1.0) }
        }
        .animation(.easeInOut(duration: 0.16), value: heights)
    }
}

// MARK: - 评分圆环

/// 评分圆环（Circle trim）+ 中间大字分数
private struct ScoreRingView: View {
    let score: Int

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 10)
            Circle()
                .trim(from: 0, to: min(max(CGFloat(score) / 100, 0), 1))
                .stroke(scoreColor(score), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: score)
            Text("\(score)")
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(.white)
                .monospacedDigit()
        }
        .frame(width: 116, height: 116)
    }
}

// MARK: - 配色与工具

private enum Palette {
    /// 主色鹦鹉黄 #FFC107
    static let accent = Color(red: 1.0, green: 0.757, blue: 0.027)
    /// 列表行 / 卡片背景（深灰）
    static let rowBackground = Color(red: 0.11, green: 0.11, blue: 0.12)
    /// 权限等警示色（红）
    static let warning = Color(red: 0.94, green: 0.35, blue: 0.36)
}

/// 分数色标：90+ 绿 / 75+ 黄 / 60+ 橙 / 其他红
private func scoreColor(_ score: Int) -> Color {
    switch score {
    case 90...: return Color(red: 0.30, green: 0.78, blue: 0.47)
    case 75...: return Color(red: 1.00, green: 0.757, blue: 0.027)
    case 60...: return Color(red: 1.00, green: 0.62, blue: 0.24)
    default:    return Color(red: 0.94, green: 0.35, blue: 0.36)
    }
}
