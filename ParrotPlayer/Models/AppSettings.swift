// 文件: AppSettings.swift — 全局应用设置模型（播放/字幕/学习/手势等偏好）

import Foundation

public struct AppSettings: Codable, Sendable {
    // 播放
    public var defaultSpeed: Float = 1.0           // 0.2...2.5
    public var rememberSpeed: Bool = true
    public var resumePlayback: Bool = true         // 断点续播
    public var autoPlayNext: Bool = true           // 自动播放下一集
    public var backgroundAudio: Bool = true
    // 字幕
    public var subtitleDisplayMode: SubtitleDisplayMode = .bilingual
    public var subtitleFontSize: Double = 18
    public var subtitlePrimaryColorHex: String = "#FFFFFF"
    public var subtitleSecondaryColorHex: String = "#FFD54F"
    public var showSubtitleBackground: Bool = true
    // 学习
    public var autoPauseOnWordTap: Bool = true      // 点词时自动暂停
    public var shadowingScoring: Bool = true
    // 投屏/硬件
    public var hardwareDecoding: Bool = true
    // 手势
    public var enableBrightnessGesture: Bool = true
    public var enableVolumeGesture: Bool = true
    public var enableSeekGesture: Bool = true

    public static let `default` = AppSettings()
    public init() {}
}
