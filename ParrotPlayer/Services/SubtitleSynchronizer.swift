// 文件: SubtitleSynchronizer.swift — 字幕时间轴同步服务
// 职责：实现 SubtitleSynchronizing 协议，提供时间轴整体平移（offset）、
//       基于两个锚点的线性校准（calibrate，平移+缩放）、双轨双语合并（merge）。
import Foundation

// MARK: - 服务协议（ARCHITECTURE.md §4 逐字定义，禁止修改）

public protocol SubtitleSynchronizing {
    /// 整体平移时间轴
    func offset(_ track: SubtitleTrack, by seconds: TimeInterval) -> SubtitleTrack
    /// 按参考视频的已知锚点线性校准（两个锚点：视频时间→字幕时间）
    func calibrate(_ track: SubtitleTrack, anchors: [(videoTime: TimeInterval, subtitleTime: TimeInterval)]) -> SubtitleTrack
    /// 合并两条字幕为双语（同 mergeBilingual 的转调，放这里一份实现）
    func merge(primary: SubtitleTrack, secondary: SubtitleTrack) -> SubtitleTrack
}

// MARK: - 同步器实现

public final class SubtitleSynchronizer: SubtitleSynchronizing {

    /// 复用解析器的双语合并逻辑，避免两份实现漂移
    private let parser: SubtitleParsing

    public init(parser: SubtitleParsing = SubtitleParser()) {
        self.parser = parser
    }

    // MARK: 整体平移

    public func offset(_ track: SubtitleTrack, by seconds: TimeInterval) -> SubtitleTrack {
        guard seconds != 0 else { return track }
        var cues: [SubtitleCue] = []
        cues.reserveCapacity(track.cues.count)
        for cue in track.cues {
            let newStart = max(0, cue.startTime + seconds)
            // 负时间 clamp 到 0 后仍需保证 end >= start
            let newEnd = max(newStart, cue.endTime + seconds)
            cues.append(SubtitleCue(startTime: newStart, endTime: newEnd,
                                    primaryText: cue.primaryText, secondaryText: cue.secondaryText))
        }
        return SubtitleTrack(label: track.label, format: track.format, language: track.language,
                             cues: cues, timeOffset: track.timeOffset)
    }

    // MARK: 两点线性校准

    public func calibrate(_ track: SubtitleTrack,
                          anchors: [(videoTime: TimeInterval, subtitleTime: TimeInterval)]) -> SubtitleTrack {
        guard !anchors.isEmpty else { return track }

        // 仅一个锚点：退化为平移校准（offset = 字幕时间 - 视频时间）
        guard anchors.count >= 2 else {
            let shift = anchors[0].subtitleTime - anchors[0].videoTime
            return offset(track, by: shift)
        }

        // 取首尾两个锚点以拉开校准基线：scale = (sub2 - sub1) / (vid2 - vid1)
        let a1 = anchors[0]
        let a2 = anchors[anchors.count - 1]
        let videoSpan = a2.videoTime - a1.videoTime
        let subtitleSpan = a2.subtitleTime - a1.subtitleTime

        // 锚点数据异常（视频时间无跨度或缩放非正）时退化为单点平移，避免时间倒流
        guard abs(videoSpan) > 0.000_1, subtitleSpan / videoSpan > 0 else {
            return offset(track, by: a1.subtitleTime - a1.videoTime)
        }
        let scale = subtitleSpan / videoSpan

        // 线性映射：newTime = a1.sub + (t - a1.vid) * scale，负时间 clamp 到 0
        var cues: [SubtitleCue] = []
        cues.reserveCapacity(track.cues.count)
        for cue in track.cues {
            let newStart = max(0, a1.subtitleTime + (cue.startTime - a1.videoTime) * scale)
            let newEnd = max(newStart, a1.subtitleTime + (cue.endTime - a1.videoTime) * scale)
            cues.append(SubtitleCue(startTime: newStart, endTime: newEnd,
                                    primaryText: cue.primaryText, secondaryText: cue.secondaryText))
        }
        return SubtitleTrack(label: track.label, format: track.format, language: track.language,
                             cues: cues, timeOffset: track.timeOffset)
    }

    // MARK: 双语合并（复用解析器实现）

    public func merge(primary: SubtitleTrack, secondary: SubtitleTrack) -> SubtitleTrack {
        parser.mergeBilingual(primary: primary, secondary: secondary)
    }
}
