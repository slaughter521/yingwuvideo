// 文件: PlayerViewModel.swift — 播放器核心状态机
// 职责：鹦鹉播放器核心 ViewModel。基于 AVFoundation 统一管理：
//       ① 播放生命周期（加载/播放/暂停/Seek/倍速/软件音量/缓冲状态）；
//       ② 字幕轨加载、双语显示、时间轴微调与句子跳转；
//       ③ 单句循环与 AB 循环（0.25s 周期时间观察驱动）；
//       ④ 播放列表与自动连播、播放历史上报（每 5s）；
//       ⑤ 截图、画中画状态、锁定。
//       公共 API 严格遵守 ARCHITECTURE.md §5（其他模块只调用不修改）。
// 依赖：SubtitleParsing 协议（Services/SubtitleParser.swift 已提供实现类 SubtitleParser）；
//       HistoryStoring 协议（定义见 ARCHITECTURE.md §4，实现位于 Services/HistoryStore.swift，
//       由并行任务提供，本文件仅按协议类型引用，不依赖具体实现）。
import Foundation
import AVFoundation
import UIKit

@MainActor
public final class PlayerViewModel: ObservableObject {

    // MARK: - 播放状态（§5 逐字实现，private(set) 外部只读）

    @Published public private(set) var player: AVPlayer
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var isBuffering: Bool = false
    @Published public private(set) var currentItem: VideoItem?
    @Published public private(set) var rate: Float = 1.0            // 0.2...2.5 无级
    @Published public private(set) var volume: Float = 1.0          // 软件音量（player.volume，非系统音量）
    @Published public private(set) var isPiPActive: Bool = false
    @Published public private(set) var errorMessage: String?

    // MARK: - 字幕状态（§5）

    @Published public var subtitleTrack: SubtitleTrack?
    @Published public var secondaryTrack: SubtitleTrack?            // 双语第二轨
    @Published public var displayMode: SubtitleDisplayMode = .bilingual
    @Published public var activeCue: SubtitleCue?

    // MARK: - 循环（§5）

    @Published public var loopMode: LoopMode = .off {
        didSet {
            // 退出单句循环时释放锁定的句子与剩余次数
            if oldValue == .sentence, loopMode != .sentence {
                lockedSentenceCue = nil
                remainingRepeats = nil
            }
        }
    }
    @Published public var loopA: TimeInterval?                      // AB 起点
    @Published public var loopB: TimeInterval?                      // AB 终点
    @Published public var sentenceRepeatCount: Int = 0              // 0=无限

    // MARK: - 控件显隐与锁定（§5）

    @Published public var controlsVisible: Bool = true
    @Published public var isLocked: Bool = false

    // MARK: - 播放列表（§5：普通属性，非 @Published，UI 可随 currentItem 变化刷新）

    public var playlist: [VideoItem] = []
    public var currentIndex: Int = 0

    // MARK: - 自动连播开关（超出 §5 的扩展：对应 AppSettings.autoPlayNext，默认开启）

    /// 播放到结尾后自动播放播放列表下一项
    public var autoPlayNext: Bool = true

    // MARK: - 依赖服务

    /// 字幕解析服务（SubtitleParser.swift 已提供实现类 SubtitleParser，遵循 SubtitleParsing）
    private let subtitleParser: SubtitleParsing = SubtitleParser()

    /// 播放历史/断点续播存储（HistoryStoring 协议定义见 ARCHITECTURE.md §4，
    /// 具体实现位于 Services/HistoryStore.swift 由并行任务提供，此处按协议类型注入）
    public var historyStore: HistoryStoring?

    // MARK: - 私有观察者与内部状态

    private var timeObserverToken: Any?
    private var statusObservation: NSKeyValueObservation?
    private var loadedTimeRangesObservation: NSKeyValueObservation?
    private var itemNotificationTokens: [NSObjectProtocol] = []
    private var pipStatusToken: NSObjectProtocol?
    /// 单句循环锁定的句子（repeatCurrentSentence 设置；nil 时跟随 activeCue）
    private var lockedSentenceCue: SubtitleCue?
    /// 单句循环剩余次数（nil=无限；>0 时递减，归零自动退出循环）
    private var remainingRepeats: Int?
    /// 上次历史保存时对应的播放位置（nil=尚未保存过）
    private var lastHistorySaveTime: TimeInterval?

    // MARK: - 常量

    private static let periodicInterval: TimeInterval = 0.25       // 周期时间观察间隔（秒）
    private static let historyInterval: TimeInterval = 5           // 历史记录上报间隔（秒）
    private static let minRate: Float = 0.2
    private static let maxRate: Float = 2.5
    private static let frameStep: TimeInterval = 1.0 / 30.0        // 逐帧步长（按 30fps）
    private static let bufferThreshold: TimeInterval = 2.0         // 缓冲落后播放位置视为正在缓冲的阈值

    // MARK: - 生命周期

    public init() {
        self.player = AVPlayer()
        observePeriodicTime()
        observePiPStatus()
    }

    deinit {
        // SE-0327（Swift 5.9）：@MainActor 类的 deinit 可直接访问存储属性并调用非隔离 API。
        let player = self.player
        // 周期时间观察者
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
        // KVO 观察者
        statusObservation?.invalidate()
        loadedTimeRangesObservation?.invalidate()
        // 通知观察者（block-based 必须用返回的 token 逐个移除）
        let center = NotificationCenter.default
        itemNotificationTokens.forEach { center.removeObserver($0) }
        if let token = pipStatusToken {
            center.removeObserver(token)
        }
        // 退出前保存最后一次播放进度
        if let item = currentItem, duration > 0, currentTime > 0 {
            historyStore?.record(video: item, position: currentTime, duration: duration)
        }
    }

    // MARK: - 加载与播放

    /// 加载视频并自动播放。playlist 非空时同步更新播放列表与索引；
    /// startAt 优先，否则回退到 item.resumePosition / historyStore 断点。
    public func load(_ item: VideoItem, playlist: [VideoItem] = [], startAt: TimeInterval? = nil) {
        // URL 有效性校验：无效时不创建播放项，仅提示，绝不崩溃
        if item.kind == .local, !FileManager.default.fileExists(atPath: item.url.path) {
            errorMessage = "本地视频文件不存在或已被移动：\(item.title)"
            return
        }
        if item.kind == .remoteURL {
            let scheme = item.url.scheme?.lowercased()
            if scheme != "http" && scheme != "https" {
                errorMessage = "无效的视频地址：\(item.url.absoluteString)"
                return
            }
        }

        // 保存上一个视频的播放进度
        recordHistoryIfNeeded(force: true)

        // 更新播放列表与索引
        if !playlist.isEmpty {
            self.playlist = playlist
            self.currentIndex = playlist.firstIndex(where: { $0.id == item.id }) ?? 0
        }

        // 组装新的播放项并绑定观察者
        let playerItem = AVPlayerItem(url: item.url)
        unbindCurrentItem()
        bindCurrentItem(playerItem)
        player.replaceCurrentItem(with: playerItem)

        // 复位播放与循环状态
        currentItem = item
        currentTime = 0
        duration = 0
        isBuffering = true
        isPlaying = false
        activeCue = nil
        loopMode = .off
        loopA = nil
        loopB = nil
        sentenceRepeatCount = 0
        lastHistorySaveTime = nil
        errorMessage = nil

        // 自动加载匹配到的外挂字幕（subtitlePath 为本地路径或 URL 字符串）
        if let path = item.subtitlePath, !path.isEmpty {
            let subtitleURL: URL
            if path.hasPrefix("/") {
                subtitleURL = URL(fileURLWithPath: path)
            } else if let parsed = URL(string: path), parsed.scheme != nil {
                subtitleURL = parsed
            } else {
                subtitleURL = URL(fileURLWithPath: path)
            }
            loadSubtitle(from: subtitleURL)
        } else {
            subtitleTrack = nil
            secondaryTrack = nil
        }

        // 断点续播：startAt 优先，其次 item.resumePosition，最后 historyStore 记录
        let start = startAt
            ?? (item.resumePosition > 0 ? item.resumePosition : (historyStore?.resumePosition(for: item.id) ?? 0))
        if start > 0 {
            seekInternal(to: start)
        }

        // 自动播放（play() 内部会恢复用户设定的倍速）
        play()
    }

    public func play() {
        player.rate = rate
        player.play()
        isPlaying = true
    }

    public func pause() {
        player.pause()
        isPlaying = false
        recordHistoryIfNeeded(force: true)
    }

    public func togglePlay() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// 跳转到指定时间。precise 时使用零公差精确 seek（关键帧对齐到精确帧）。
    /// 锁定时屏蔽（外部 View 读 isLocked 控制 UI，此处为纵深防御）。
    public func seek(to time: TimeInterval, precise: Bool = false) {
        guard !isLocked else { return }
        seekInternal(to: time, precise: precise)
    }

    /// 相对跳转（快进/快退）
    public func seek(by offset: TimeInterval) {
        seek(to: currentTime + offset)
    }

    /// 播放列表下一项；已到最后一项则提示
    public func next() {
        guard !playlist.isEmpty else {
            errorMessage = "播放列表为空"
            return
        }
        let index = currentIndex + 1
        guard index < playlist.count else {
            errorMessage = "已经是播放列表的最后一项了"
            return
        }
        load(playlist[index])
    }

    /// 播放列表上一项；第一项时重播当前视频
    public func previous() {
        guard !playlist.isEmpty else {
            errorMessage = "播放列表为空"
            return
        }
        let index = currentIndex - 1
        guard index >= 0 else {
            seekInternal(to: 0)
            if !isPlaying { play() }
            return
        }
        load(playlist[index])
    }

    /// 设置倍速（无级，钳制在 0.2...2.5）；播放中立即生效
    public func setRate(_ rate: Float) {
        let clamped = min(max(rate, Self.minRate), Self.maxRate)
        self.rate = clamped
        if isPlaying {
            player.rate = clamped
        }
    }

    /// 设置软件音量（player.volume，0...1）
    public func setVolume(_ v: Float) {
        let clamped = min(max(v, 0), 1)
        volume = clamped
        player.volume = clamped
    }

    /// 逐帧步进（预留实现：按 1/30s 跳转并暂停）
    public func stepFrame(forward: Bool) {
        pause()
        seek(by: forward ? Self.frameStep : -Self.frameStep)
    }

    // MARK: - 字幕控制

    /// 加载外挂字幕（自动识别 SRT/ASS/VTT/LRC），失败时以 errorMessage 提示中文原因
    public func loadSubtitle(from url: URL) {
        do {
            let track = try subtitleParser.parse(fileURL: url)
            subtitleTrack = track
            secondaryTrack = nil
            lockedSentenceCue = nil
            updateActiveCue()
        } catch {
            subtitleTrack = nil
            secondaryTrack = nil
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "字幕加载失败：\(url.lastPathComponent)"
        }
    }

    /// 加载双语字幕：解析两条字幕轨并按时间轴合并（±0.5s 容差），合并结果写入 subtitleTrack
    public func loadBilingualSubtitles(primary primaryURL: URL, secondary secondaryURL: URL) {
        do {
            let primaryTrack = try subtitleParser.parse(fileURL: primaryURL)
            let secondary = try subtitleParser.parse(fileURL: secondaryURL)
            let merged = subtitleParser.mergeBilingual(primary: primaryTrack, secondary: secondary)
            subtitleTrack = merged
            secondaryTrack = nil
            lockedSentenceCue = nil
            updateActiveCue()
        } catch {
            subtitleTrack = nil
            secondaryTrack = nil
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "字幕加载失败：\(secondaryURL.lastPathComponent)"
        }
    }

    public func setDisplayMode(_ mode: SubtitleDisplayMode) {
        displayMode = mode
    }

    /// 时间轴整体微调（正数=字幕延后），主/次字幕轨同步生效并立即刷新 activeCue
    public func adjustSubtitleOffset(by seconds: TimeInterval) {
        if var track = subtitleTrack {
            track.timeOffset += seconds
            subtitleTrack = track
        }
        if var track = secondaryTrack {
            track.timeOffset += seconds
            secondaryTrack = track
        }
        updateActiveCue()
    }

    /// 跳转到指定字幕句并播放
    public func jumpToCue(_ cue: SubtitleCue) {
        seek(to: cue.startTime)
        if !isPlaying { play() }
    }

    // MARK: - 学习辅助（句子级操作）

    /// 上一句：当前句播放超过 2 秒先重播当前句，否则跳上一句
    public func playPreviousSentence() {
        guard let track = subtitleTrack, !track.cues.isEmpty else {
            errorMessage = "尚未加载字幕，无法定位句子"
            return
        }
        let index = track.activeCueIndex(at: currentTime)
        let targetIndex: Int
        if index >= 0 {
            let elapsed = currentTime - track.cues[index].startTime
            targetIndex = elapsed > 2.0 ? index : max(index - 1, 0)
        } else {
            targetIndex = track.cues.lastIndex(where: { $0.startTime < currentTime }) ?? 0
        }
        jumpToCue(track.cues[targetIndex])
    }

    /// 下一句：跳到当前句的后一句；不在任何句内时跳到下一句开始的句子
    public func playNextSentence() {
        guard let track = subtitleTrack, !track.cues.isEmpty else {
            errorMessage = "尚未加载字幕，无法定位句子"
            return
        }
        let index = track.activeCueIndex(at: currentTime)
        let targetIndex: Int
        if index >= 0 {
            targetIndex = min(index + 1, track.cues.count - 1)
        } else {
            targetIndex = track.cues.firstIndex(where: { $0.startTime > currentTime })
                ?? (track.cues.count - 1)
        }
        jumpToCue(track.cues[targetIndex])
    }

    /// 单句循环：锁定当前（或最近的）句子，循环播放；count=0 表示无限，>0 表示重复指定次数
    public func repeatCurrentSentence(count: Int = 0) {
        guard let track = subtitleTrack, !track.cues.isEmpty else {
            errorMessage = "尚未加载字幕，无法使用单句循环"
            return
        }
        guard let cue = track.activeCue(at: currentTime)
                ?? nearestCue(to: currentTime, in: track) else {
            errorMessage = "当前位置附近没有字幕，无法使用单句循环"
            return
        }
        lockedSentenceCue = cue
        sentenceRepeatCount = max(count, 0)
        remainingRepeats = sentenceRepeatCount > 0 ? sentenceRepeatCount : nil
        loopMode = .sentence
        seek(to: cue.startTime)
        if !isPlaying { play() }
    }

    /// 设置 AB 循环区间；start/end 均为 nil 时清除；单侧设置时暂存待补齐
    public func setABLoop(start: TimeInterval?, end: TimeInterval?) {
        if start == nil, end == nil {
            loopA = nil
            loopB = nil
            loopMode = .off
            return
        }
        let newA = start ?? loopA
        let newB = end ?? loopB
        if let a = newA, let b = newB, b > a {
            loopA = a
            loopB = b
            loopMode = .ab
        } else {
            // 暂存单侧点（如先设 A 点），补齐并满足 b > a 后才进入循环
            loopA = newA
            loopB = newB
        }
    }

    /// 切换 AB 循环：无 A 点时记录 A → 有 A 无 B 时记录 B 并生效 → 再次调用关闭并清除
    public func toggleABLoop() {
        switch loopMode {
        case .ab:
            if loopB != nil {
                loopMode = .off
                loopA = nil
                loopB = nil
            } else {
                let now = currentTime
                if let a = loopA, now > a {
                    loopB = now
                } else {
                    loopA = now
                    loopB = nil
                }
            }
        default:
            loopMode = .ab
            loopA = currentTime
            loopB = nil
        }
    }

    // MARK: - 截图

    /// 同步截图（§5 签名）：本地文件直接生成；远程资源同步截图会阻塞主线程，返回 nil，
    /// 远程请使用 captureScreenshot(completion:)
    @discardableResult
    public func captureScreenshot() -> UIImage? {
        guard currentItem?.kind == .local, let asset = currentItem?.asset else { return nil }
        let generator = Self.makeImageGenerator(asset: asset)
        let time = CMTime(seconds: max(currentTime, 0), preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// 异步截图：本地用 asset 同步生成（速度可控），远程用
    /// AVAssetImageGenerator(asset:) + generateCGImagesAsynchronously，完成后回主线程回调
    public func captureScreenshot(completion: @escaping (UIImage?) -> Void) {
        guard let asset = currentItem?.asset else {
            completion(nil)
            return
        }
        let generator = Self.makeImageGenerator(asset: asset)
        let time = CMTime(seconds: max(currentTime, 0), preferredTimescale: 600)
        if currentItem?.kind == .local {
            // 本地文件：同步生成
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                completion(UIImage(cgImage: cgImage))
            } else {
                completion(nil)
            }
        } else {
            // 远程资源：异步生成，避免阻塞主线程等待网络加载
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, _, _ in
                let image = cgImage.map { UIImage(cgImage: $0) }
                Task { @MainActor in
                    completion(image)
                }
            }
        }
    }

    // MARK: - 画中画

    /// 进入画中画：仅切换状态并发通知；真实 PiP 控制器由 View 层 AVPlayerViewController 提供
    public func enterPiP() {
        guard currentItem != nil else {
            errorMessage = "尚未加载视频，无法进入画中画"
            return
        }
        guard !isPiPActive else { return }
        isPiPActive = true
        NotificationCenter.default.post(name: .parrotPlayerWillEnterPiP, object: self)
    }

    /// 退出画中画
    public func exitPiP() {
        guard isPiPActive else { return }
        isPiPActive = false
        NotificationCenter.default.post(name: .parrotPlayerWillExitPiP, object: self)
    }

    // MARK: - 锁定

    /// 切换锁定：锁定后 seek 等操作被屏蔽（外部 View 读 isLocked 更新 UI）
    public func toggleLock() {
        isLocked.toggle()
    }

    // MARK: - 私有：时间观察与循环逻辑

    /// 注册周期时间观察（每 0.25s），驱动进度、字幕、循环与历史记录。
    /// block 内以 [weak self] + Task { @MainActor } 防环，deinit 前移除观察者。
    private func observePeriodicTime() {
        let interval = CMTime(seconds: Self.periodicInterval, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let seconds = CMTimeGetSeconds(time)
                self.handlePeriodicTime(seconds)
            }
        }
    }

    /// 周期回调入口：更新 currentTime → 刷新 activeCue → 处理循环 → 节流上报历史
    private func handlePeriodicTime(_ seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0 else { return }
        currentTime = seconds
        updateActiveCue()
        handleLooping()
        recordHistoryIfNeeded()
    }

    /// 循环逻辑：单句循环到达 cue.endTime 回跳 cue.startTime（sentenceRepeatCount=0 无限）；
    /// AB 循环到达 loopB 回跳 loopA
    private func handleLooping() {
        switch loopMode {
        case .sentence:
            guard let cue = lockedSentenceCue ?? activeCue else { return }
            guard currentTime >= cue.endTime - 0.05 else { return }
            seekInternal(to: cue.startTime)
            if !isPlaying { play() }
            if let remaining = remainingRepeats {
                if remaining <= 1 {
                    // 次数用尽：退出循环（didSet 会释放锁定句子与剩余次数）
                    loopMode = .off
                } else {
                    remainingRepeats = remaining - 1
                }
            }
        case .ab:
            guard let a = loopA, let b = loopB, b > a else { return }
            guard currentTime >= b - 0.05 else { return }
            seekInternal(to: a)
            if !isPlaying { play() }
        case .off:
            break
        }
    }

    /// 刷新当前生效的字幕句（仅变化时赋值，避免多余刷新）
    private func updateActiveCue() {
        let cue = subtitleTrack?.activeCue(at: currentTime)
        if cue?.id != activeCue?.id {
            activeCue = cue
        }
    }

    /// 历史记录节流上报：每 5s 或强制时通过 historyStore?.record(video:position:duration:)
    private func recordHistoryIfNeeded(force: Bool = false) {
        guard let item = currentItem else { return }
        guard duration > 0, currentTime > 0 else { return }
        if !force, let last = lastHistorySaveTime, currentTime - last < Self.historyInterval {
            return
        }
        lastHistorySaveTime = currentTime
        historyStore?.record(video: item, position: currentTime, duration: duration)
    }

    // MARK: - 私有：播放项观察（KVO + 通知）

    private func bindCurrentItem(_ item: AVPlayerItem) {
        let center = NotificationCenter.default

        // 播放到结尾：连播 / 循环回跳 / 复位
        itemNotificationTokens.append(center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleDidPlayToEndTime()
            }
        })

        // 缓冲中断（网络卡顿等）：标记为正在缓冲
        itemNotificationTokens.append(center.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isBuffering = true
            }
        })

        // 播放中途失败：中文错误提示
        itemNotificationTokens.append(center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.handleFailedToPlayToEndTime(note)
            }
        })

        // status KVO：readyToPlay 更新时长；failed 上报错误
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleItemStatusChanged()
            }
        }

        // loadedTimeRanges KVO：驱动缓冲状态
        loadedTimeRangesObservation = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleLoadedTimeRangesChanged()
            }
        }
    }

    private func unbindCurrentItem() {
        statusObservation?.invalidate()
        statusObservation = nil
        loadedTimeRangesObservation?.invalidate()
        loadedTimeRangesObservation = nil
        let center = NotificationCenter.default
        itemNotificationTokens.forEach { center.removeObserver($0) }
        itemNotificationTokens.removeAll()
    }

    private func handleItemStatusChanged() {
        guard let item = player.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            let seconds = CMTimeGetSeconds(item.duration)
            if seconds.isFinite, seconds > 0 {
                duration = seconds
            }
            isBuffering = !item.isPlaybackLikelyToKeepUp
        case .failed:
            isBuffering = false
            isPlaying = false
            errorMessage = "视频加载失败：\(item.error?.localizedDescription ?? "未知错误")"
        case .unknownToStatus:
            isBuffering = true
        @unknown default:
            break
        }
    }

    private func handleLoadedTimeRangesChanged() {
        guard let ranges = player.currentItem?.loadedTimeRanges as? [NSValue], !ranges.isEmpty else {
            return
        }
        let timeRanges = ranges.compactMap { $0.timeRangeValue }
        guard let furthest = timeRanges.max(by: {
            CMTimeGetSeconds($0.end) < CMTimeGetSeconds($1.end)
        }) else { return }
        let bufferedEnd = CMTimeGetSeconds(furthest.end)
        guard bufferedEnd.isFinite else { return }
        if player.currentItem?.isPlaybackLikelyToKeepUp == true {
            isBuffering = false
        } else {
            // 缓冲进度落后播放位置超过阈值视为正在缓冲
            isBuffering = bufferedEnd - currentTime < Self.bufferThreshold
        }
    }

    private func handleDidPlayToEndTime() {
        recordHistoryIfNeeded(force: true)
        isBuffering = false

        // 循环优先于连播：周期观察此时可能已停止触发，在此立即回跳
        if loopMode == .sentence, let cue = lockedSentenceCue ?? activeCue {
            seekInternal(to: cue.startTime)
            play()
            return
        }
        if loopMode == .ab, let a = loopA {
            seekInternal(to: a)
            play()
            return
        }

        // 自动连播
        if autoPlayNext {
            let nextIndex = currentIndex + 1
            if !playlist.isEmpty && nextIndex < playlist.count {
                load(playlist[nextIndex])
                return
            }
        }

        // 列表播完或未开启连播：复位到开头并暂停
        isPlaying = false
        seekInternal(to: 0)
        updateActiveCue()
    }

    private func handleFailedToPlayToEndTime(_ note: Notification) {
        let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
        errorMessage = "播放中断：\(error?.localizedDescription ?? "未知错误")"
        isPlaying = false
        isBuffering = false
    }

    // MARK: - 私有：画中画状态观察

    /// 观察 View 层（AVPlayerViewController）回传的画中画状态变化，userInfo["isActive"]: Bool
    private func observePiPStatus() {
        pipStatusToken = NotificationCenter.default.addObserver(
            forName: .parrotPlayerPiPStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let isActive = (note.userInfo?["isActive"] as? Bool) ?? false
            Task { @MainActor [weak self] in
                self?.isPiPActive = isActive
            }
        }
    }

    // MARK: - 私有：工具

    /// 内部 seek（锁定不影响循环/续播/连播的跳转），成功后立即刷新 currentTime 与 activeCue
    private func seekInternal(to time: TimeInterval, precise: Bool = false) {
        let upperBound = duration > 0 ? duration : time
        let target = min(max(time, 0), upperBound)
        let cmTime = CMTime(seconds: target, preferredTimescale: 600)
        if precise {
            player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            player.seek(to: cmTime)
        }
        currentTime = target
        updateActiveCue()
    }

    /// 查找距离指定时间最近的字幕句（区间内优先，否则取前一句/后一句）
    private func nearestCue(to time: TimeInterval, in track: SubtitleTrack) -> SubtitleCue? {
        track.cues.last(where: { $0.startTime <= time })
            ?? track.cues.first(where: { $0.startTime > time })
    }

    private static func makeImageGenerator(asset: AVAsset) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return generator
    }
}

// MARK: - 通知名（与 View 层 AVPlayerViewController 的画中画协作）

public extension Notification.Name {
    /// View 层观察后进入画中画
    static let parrotPlayerWillEnterPiP = Notification.Name("ParrotPlayerWillEnterPiP")
    /// View 层观察后退出画中画
    static let parrotPlayerWillExitPiP = Notification.Name("ParrotPlayerWillExitPiP")
    /// View 层画中画状态变化时回传，userInfo["isActive"]: Bool
    static let parrotPlayerPiPStatusDidChange = Notification.Name("ParrotPlayerPiPStatusDidChange")
}
