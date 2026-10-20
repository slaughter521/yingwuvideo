// 文件: SubtitleModels.swift — 字幕数据模型（单条字幕、字幕轨、显示模式、循环模式）

import Foundation

public enum SubtitleFormat: String, Codable, Sendable {
    case srt, ass, vtt, lrc, unknown
}

/// 单条字幕（时间单位：秒）
public struct SubtitleCue: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var primaryText: String        // 主字幕（通常英文/源语言）
    public var secondaryText: String?     // 次字幕（通常中文译文）

    public init(startTime: TimeInterval, endTime: TimeInterval,
                primaryText: String, secondaryText: String? = nil) {
        self.startTime = startTime
        self.endTime = endTime
        self.primaryText = primaryText
        self.secondaryText = secondaryText
    }
}

/// 一条字幕轨（可含中英双语）
public struct SubtitleTrack: Identifiable, Codable, Sendable {
    public var id: UUID = UUID()
    public var label: String              // 如 "English" / "中文" / "外挂字幕"
    public var format: SubtitleFormat
    public var language: String           // BCP-47, 如 "en"/"zh-Hans"
    public var cues: [SubtitleCue]
    /// 时间轴偏移（秒，正数=字幕延后）
    public var timeOffset: TimeInterval = 0

    public init(label: String, format: SubtitleFormat, language: String,
                cues: [SubtitleCue], timeOffset: TimeInterval = 0) {
        self.label = label
        self.format = format
        self.language = language
        self.cues = cues
        self.timeOffset = timeOffset
    }

    /// 应用 timeOffset 后，返回当前时间生效的 cue
    public func activeCue(at time: TimeInterval) -> SubtitleCue? {
        let t = time - timeOffset
        return cues.first { t >= $0.startTime && t <= $0.endTime }
    }
    /// 当前 cue 的索引（-1 表示无）
    public func activeCueIndex(at time: TimeInterval) -> Int {
        let t = time - timeOffset
        return cues.firstIndex { t >= $0.startTime && t <= $0.endTime } ?? -1
    }
}

/// 字幕显示模式
public enum SubtitleDisplayMode: String, Codable, CaseIterable, Sendable {
    case bilingual   // 双语
    case primaryOnly // 仅主语言
    case secondaryOnly // 仅次语言
    case hidden      // 隐藏
}

/// 循环模式
public enum LoopMode: String, Codable, Sendable {
    case off        // 不循环
    case sentence   // 单句循环
    case ab         // AB 循环
}
