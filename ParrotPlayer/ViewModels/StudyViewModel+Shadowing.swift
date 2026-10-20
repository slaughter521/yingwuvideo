// 文件: StudyViewModel+Shadowing.swift — 跟读练习关注点分离实现（评分 / 录音 / 原声包络提取 / 对比播放）
// 职责：
//   1. ShadowingScorer：纯静态评分算法（时长吻合度 40% + 音量包络余弦相似度 40% + 起止静音修剪奖励 20%）
//   2. ShadowingRecorder：AVAudioRecorder 封装（AAC / 44.1kHz / 单声道 / high，文件存 Documents/Shadowing/<UUID>.m4a）
//   3. extractVolumeEnvelope：原声音量包络提取（AVAudioFile + AVAudioPCMBuffer，100ms 一帧 RMS，归一化）
//   4. ShadowingPlayer：AVAudioPlayer 封装，用于原音与录音的对比试听
// 说明：本文件不引用任何 UI 类型，可被 StudyViewModel 与学习页面直接复用。

import Foundation
import AVFoundation
import Combine

// MARK: - 录音错误

/// 录音错误（中文提示）
public enum ShadowingRecorderError: Error, LocalizedError {
    /// 未获得麦克风权限
    case recordPermissionDenied
    /// 录音启动失败
    case recordStartFailed

    public var errorDescription: String? {
        switch self {
        case .recordPermissionDenied:
            return "未获得麦克风权限，请在「设置 › 隐私 › 麦克风」中开启后重试"
        case .recordStartFailed:
            return "录音启动失败，请重试"
        }
    }
}

// MARK: - 评分算法

/// 跟读评分器：纯算法、无外部依赖、无共享状态。
/// 评分综合三个维度加权求和，取整到 0-100。
@MainActor
public struct ShadowingScorer {

    /// 时长吻合度权重（40%）
    private static let durationWeight: Float = 0.4
    /// 音量包络余弦相似度权重（40%）
    private static let envelopeWeight: Float = 0.4
    /// 起止静音修剪奖励权重（20%）
    private static let trimWeight: Float = 0.2

    /// 「有声帧」判定阈值（归一化 RMS 大于等于该值）
    private static let silenceThreshold: Float = 0.1
    /// 起止位置允许的误差（帧；每帧 100ms，±1 帧以内不扣分）
    private static let trimToleranceFrames: Float = 1.0
    /// 两条包络长度不一致时统一重采样到的比较网格帧数
    private static let resampleFrameCount = 100

    /// 跟读综合评分（0-100）
    ///
    /// ## 评分公式
    /// ```
    /// score = round( 100 × ( 0.4 × durationScore + 0.4 × cosineScore + 0.2 × trimScore ) )
    /// ```
    ///
    /// ### 1. 时长吻合度 durationScore（权重 40%）
    /// ```
    /// durationScore = clamp(1 - |recordDuration - originalDuration| / originalDuration, 0, 1)
    /// ```
    /// 以原句时长为基准的相对误差：完全等长得 1 分，误差达到原句时长记 0 分。
    /// originalDuration ≤ 0 或时长非法（NaN / Infinity）时记 0 分。
    ///
    /// ### 2. 音量包络余弦相似度 cosineScore（权重 40%）
    /// 两条包络（每帧一个 0...1 的归一化 RMS）帧数一致时直接比较；
    /// 不一致时先线性重采样到同一网格（`resampleFrameCount` 帧）再比较，
    /// 使该维度反映「音量起伏形状」而非绝对时长（时长差异由第 1 项单独计分）：
    /// ```
    /// cosineScore = clamp( dot(a, b) / ( ‖a‖ × ‖b‖ ), 0, 1 )
    /// ```
    /// 包络非负，余弦值域即 [0, 1]；任一包络为空或范数为 0（全静音）时记 0 分。
    ///
    /// ### 3. 起止静音修剪奖励 trimScore（权重 20%）
    /// 以 `silenceThreshold` 为「有声帧」阈值，分别找出原音与录音的首个 / 末个有声帧，
    /// 计算首尾偏移（仅超出 `trimToleranceFrames` 帧容差的部分计入）：
    /// ```
    /// trimScore = clamp( 1 - (headGap + tailGap) / originalFrames, 0, 1 )
    /// ```
    /// headGap / tailGap 为录音相对原音的首 / 尾有声帧索引偏移（帧），
    /// originalFrames 为原音包络帧数；任一侧全静音（找不到有声帧）记 0 分。
    ///
    /// ## 健壮性
    /// 所有非法输入（负时长、NaN、空数组等）一律 clamp 到合法区间，不会崩溃。
    ///
    /// - Parameters:
    ///   - originalDuration: 原句时长（秒）
    ///   - recordDuration: 录音时长（秒）
    ///   - originalVolumeEnvelope: 原音音量包络（每帧一个 0...1 幅度值）
    ///   - recordVolumeEnvelope: 录音音量包络
    /// - Returns: 0-100 的整数评分
    public static func score(
        originalDuration: TimeInterval,
        recordDuration: TimeInterval,
        originalVolumeEnvelope: [Float],
        recordVolumeEnvelope: [Float]
    ) -> Int {
        let durationScore = Self.durationSimilarity(original: originalDuration, record: recordDuration)
        let cosineScore = Self.cosineSimilarity(original: originalVolumeEnvelope, record: recordVolumeEnvelope)
        let trimScore = Self.trimBonus(original: originalVolumeEnvelope, record: recordVolumeEnvelope)

        let total = Self.durationWeight * durationScore
            + Self.envelopeWeight * cosineScore
            + Self.trimWeight * trimScore
        // 加权和理论上已在 0...1，此处 clamp 防御浮点误差与非法输入
        let clamped = Self.clamp01(total)
        return Int((clamped * 100).rounded())
    }

    /// 时长吻合度（0...1）：相对误差越小越接近 1
    private static func durationSimilarity(original: TimeInterval, record: TimeInterval) -> Float {
        guard original.isFinite, record.isFinite, original > 0, record >= 0 else { return 0 }
        let relativeError = abs(record - original) / original
        return clamp01(1 - Float(relativeError))
    }

    /// 音量包络余弦相似度（0...1）；长度不一致时先线性重采样到同一网格
    private static func cosineSimilarity(original: [Float], record: [Float]) -> Float {
        guard !original.isEmpty, !record.isEmpty else { return 0 }

        let a: [Float]
        let b: [Float]
        if original.count == record.count {
            a = original
            b = record
        } else {
            a = resample(original, to: Self.resampleFrameCount)
            b = resample(record, to: Self.resampleFrameCount)
        }
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for index in 0..<a.count {
            // 非法数值（NaN 等）按 0 处理，避免污染点积
            let x = a[index].isFinite ? a[index] : 0
            let y = b[index].isFinite ? b[index] : 0
            dot += x * y
            normA += x * x
            normB += y * y
        }
        guard normA > 0, normB > 0 else { return 0 }
        return clamp01(dot / (normA.squareRoot() * normB.squareRoot()))
    }

    /// 起止静音修剪奖励（0...1）
    private static func trimBonus(original: [Float], record: [Float]) -> Float {
        guard !original.isEmpty, !record.isEmpty else { return 0 }
        // 原音全静音：无参照，记 0 分
        guard let originalFirst = firstActiveFrame(in: original),
              let originalLast = lastActiveFrame(in: original) else {
            return 0
        }
        // 录音全静音（没录到声音）：记 0 分
        guard let recordFirst = firstActiveFrame(in: record),
              let recordLast = lastActiveFrame(in: record) else {
            return 0
        }
        let headGap = max(0, abs(Float(recordFirst - originalFirst)) - Self.trimToleranceFrames)
        let tailGap = max(0, abs(Float(recordLast - originalLast)) - Self.trimToleranceFrames)
        let originalFrames = Float(max(original.count, 1))
        return clamp01(1 - (headGap + tailGap) / originalFrames)
    }

    /// 首个「有声帧」索引（RMS ≥ silenceThreshold）；全静音返回 nil
    private static func firstActiveFrame(in envelope: [Float]) -> Int? {
        envelope.firstIndex { $0 >= Self.silenceThreshold }
    }

    /// 末个「有声帧」索引；全静音返回 nil
    private static func lastActiveFrame(in envelope: [Float]) -> Int? {
        for index in stride(from: envelope.count - 1, through: 0, by: -1) {
            if envelope[index] >= Self.silenceThreshold { return index }
        }
        return nil
    }

    /// 线性重采样到指定帧数（长度不一致时用于统一比较网格）
    private static func resample(_ values: [Float], to frameCount: Int) -> [Float] {
        guard !values.isEmpty, frameCount > 0 else { return [] }
        if values.count == 1 { return [Float](repeating: values[0], count: frameCount) }
        if frameCount == 1 { return [values[values.count - 1]] }
        var result = [Float](repeating: 0, count: frameCount)
        let lastIndex = values.count - 1
        let scale = Float(lastIndex) / Float(frameCount - 1)
        for index in 0..<frameCount {
            let position = Float(index) * scale
            let lowerIndex = Int(position.rounded(.down))
            if lowerIndex >= lastIndex {
                result[index] = values[lastIndex]
            } else {
                let fraction = position - Float(lowerIndex)
                result[index] = values[lowerIndex] * (1 - fraction) + values[lowerIndex + 1] * fraction
            }
        }
        return result
    }

    /// 将数值 clamp 到 0...1；NaN 与非有限值记 0
    private static func clamp01(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

// MARK: - 录音封装

/// 跟读录音器：封装 AVAudioRecorder。
/// 录音设置：AAC（kAudioFormatMPEG4AAC）/ 44.1kHz / 单声道 / 高质量；
/// 文件存放于 Documents/Shadowing/<UUID>.m4a。
/// 注意：开始录音会把音频会话切换为 playAndRecord，可能中断其他播放，请在跟读场景使用。
@MainActor
public final class ShadowingRecorder: ObservableObject {

    /// 是否正在录音
    @Published public private(set) var isRecording: Bool = false
    /// 录音过程错误提示（中文）
    @Published public private(set) var errorMessage: String?

    private var audioRecorder: AVAudioRecorder?
    /// 当前（或上一次）录音文件地址
    private var currentRecordingURL: URL?

    public init() {}

    /// 录音文件目录：Documents/Shadowing
    private static var shadowingDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shadowing", isDirectory: true)
    }

    /// 检查并请求录音权限（基于 AVAudioSession.recordPermission）。
    /// 已授权返回 true；已拒绝返回 false；未决定时弹出系统授权框并等待用户选择。
    /// - Returns: 当前是否拥有录音权限
    public func requestPermissionIfNeeded() async -> Bool {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            // 显式闭包返回类型 + 显式 return，避免依赖单表达式隐式返回的类型推断
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) -> Bool in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
                // 授权结果经上面的回调恢复当前任务，本行不会执行到
                return false
            }
        @unknown default:
            return false
        }
    }

    /// 开始录音（新文件：Documents/Shadowing/<UUID>.m4a）。
    /// 调用前应先通过 `requestPermissionIfNeeded()` 获得授权，否则抛出 `.recordPermissionDenied`。
    /// - Throws: `ShadowingRecorderError`（权限不足 / 启动失败）
    public func start() throws {
        guard AVAudioSession.sharedInstance().recordPermission == .granted else {
            throw ShadowingRecorderError.recordPermissionDenied
        }

        // 音频会话：边录边放（跟读时需要同时听到原音），默认走扬声器
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        // 准备录音文件
        let directory = Self.shadowingDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(UUID().uuidString + ".m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder.delegate = self
        recorder.prepareToRecord()
        guard recorder.record() else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw ShadowingRecorderError.recordStartFailed
        }

        audioRecorder = recorder
        currentRecordingURL = fileURL
        isRecording = true
    }

    /// 停止录音并返回录音文件地址；未在录音时返回 nil。
    /// 同时释放录音音频会话（notifyOthersOnDeactivation，尽量不影响其他播放器）。
    /// - Returns: 录音文件 URL（可直接交给 ShadowingPlayer 对比播放）
    public func stop() -> URL? {
        guard let recorder = audioRecorder else { return nil }
        recorder.stop()
        audioRecorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return currentRecordingURL
    }

    /// 取消当前录音：停止录制并删除录音文件（未在录音时删除上一次的文件）
    public func deleteCurrentRecording() {
        if let recorder = audioRecorder {
            recorder.stop()
            audioRecorder = nil
            isRecording = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        if let url = currentRecordingURL {
            try? FileManager.default.removeItem(at: url)
            currentRecordingURL = nil
        }
    }
}

// MARK: - AVAudioRecorderDelegate

extension ShadowingRecorder: AVAudioRecorderDelegate {
    /// 录音编码出错（如磁盘写满）：记录中文错误并复位录音状态
    public func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        errorMessage = "录音出错：\(error?.localizedDescription ?? "未知错误")"
        isRecording = false
        audioRecorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - 原声音量包络提取

extension ShadowingRecorder {

    /// 提取音频文件的音量包络（供 ShadowingScorer 评分使用，同样适用于用户录音）。
    ///
    /// 实现：AVAudioFile 读取 + AVAudioPCMBuffer 分帧（每帧 100ms）计算 RMS，
    /// 最后按峰值归一化到 0...1。读取在后台队列执行，不阻塞调用线程。
    /// - Parameter url: 音频文件地址（视频音轨 / 导出音频 / 录音文件均可）
    /// - Returns: 每帧一个 0...1 的幅度值；任何失败（文件不可读 / 格式不支持 / 读取错误）返回空数组
    public nonisolated static func extractVolumeEnvelope(from url: URL) async -> [Float] {
        // 显式闭包返回类型 + 显式 return，避免依赖单表达式隐式返回的类型推断；
        // dispatch 后闭包立即返回，当前任务保持挂起，直到后台读取完成经 continuation 恢复
        await withCheckedContinuation { (continuation: CheckedContinuation<[Float], Never>) -> [Float] in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.extractVolumeEnvelopeSync(from: url))
            }
            return []
        }
    }

    /// 同步实现：分帧 RMS + 峰值归一化；失败统一返回空数组
    private nonisolated static func extractVolumeEnvelopeSync(from url: URL) -> [Float] {
        guard let audioFile = try? AVAudioFile(forReading: url) else { return [] }

        let format = audioFile.processingFormat
        guard format.sampleRate > 0, format.channelCount > 0 else { return [] }

        // 每帧 100ms（44.1kHz 下约 4410 个采样点）
        let frameSize = AVAudioFrameCount((format.sampleRate * 0.1).rounded())
        guard frameSize > 0 else { return [] }

        // 用可选变量承接，兼容不同 SDK 下 AVAudioPCMBuffer 初始化器的可选性标注差异
        let bufferRef: AVAudioPCMBuffer? = AVAudioPCMBuffer(format: format, frameCapacity: frameSize)
        guard let buffer = bufferRef else { return [] }

        // 仅支持解码后最常见的 PCM Float32 / Int16，其余格式视为失败
        guard buffer.format.commonFormat == .pcmFormatFloat32
                || buffer.format.commonFormat == .pcmFormatInt16 else {
            return []
        }

        let channelCount = Int(format.channelCount)
        var envelope: [Float] = []

        while true {
            do {
                try audioFile.read(into: buffer)
            } catch {
                return []   // 读取中途失败，整体视为失败
            }
            let frameLength = Int(buffer.frameLength)
            if frameLength == 0 { break }              // 已到文件末尾
            envelope.append(rms(of: buffer, channelCount: channelCount))
            if frameLength < Int(frameSize) { break }  // 末尾不足一帧，计入后结束
        }

        // 按峰值归一化到 0...1（全静音时保持全 0）
        if let peak = envelope.max(), peak.isFinite, peak > 0 {
            return envelope.map { $0 / peak }
        }
        return envelope
    }

    /// 计算一帧 buffer 的 RMS 幅度（多声道取平均）
    private nonisolated static func rms(of buffer: AVAudioPCMBuffer, channelCount: Int) -> Float {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        var sumOfSquares: Float = 0
        var sampleCount = 0

        if buffer.format.commonFormat == .pcmFormatFloat32 {
            if let channelData = buffer.floatChannelData {
                for channel in 0..<channelCount {
                    // 不同 SDK 导入下通道指针元素的可选性可能不同，用显式可选标注兼容两种情况
                    let samples: UnsafeMutablePointer<Float>? = channelData[channel]
                    if let samples {
                        for frame in 0..<frameLength {
                            let sample = samples[frame]
                            sumOfSquares += sample * sample
                            sampleCount += 1
                        }
                    }
                }
            }
        } else if buffer.format.commonFormat == .pcmFormatInt16 {
            if let channelData = buffer.int16ChannelData {
                for channel in 0..<channelCount {
                    let samples: UnsafeMutablePointer<Int16>? = channelData[channel]
                    if let samples {
                        for frame in 0..<frameLength {
                            let sample = Float(samples[frame]) / Float(Int16.max)
                            sumOfSquares += sample * sample
                            sampleCount += 1
                        }
                    }
                }
            }
        }

        guard sampleCount > 0 else { return 0 }
        return (sumOfSquares / Float(sampleCount)).squareRoot()
    }
}

// MARK: - 对比播放封装

/// 跟读对比播放器：封装 AVAudioPlayer，用于试听原音与自己的录音。
/// 播放前自动把音频会话切换为播放类别并激活；播放结束后的会话管理交由后续播放器负责。
@MainActor
public final class ShadowingPlayer: ObservableObject {

    /// 播放错误提示（中文）
    @Published public private(set) var errorMessage: String?

    private var player: AVAudioPlayer?

    public init() {}

    /// 播放指定音频文件（自动停止上一个播放）
    /// - Parameter url: 音频文件地址
    public func play(url: URL) {
        errorMessage = nil
        stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            self.player = player
            if !player.play() {
                errorMessage = "音频播放启动失败"
            }
        } catch {
            errorMessage = "音频播放失败：\(error.localizedDescription)"
        }
    }

    /// 停止播放
    public func stop() {
        player?.stop()
        player = nil
    }
}
