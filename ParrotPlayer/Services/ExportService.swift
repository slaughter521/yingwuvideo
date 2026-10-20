// 文件: ExportService.swift — 音频导出（AVAssetExportSession → m4a）与字幕导出（SRT/VTT，应用 timeOffset）；协议见 ARCHITECTURE.md §4

import AVFoundation
import Foundation

public protocol ExportServicing {
    /// 从视频导出音频（AVAssetExportSession → m4a）
    func exportAudio(from video: VideoItem) async throws -> URL
    /// 导出字幕文件（SRT 格式，带时间轴偏移应用）
    func exportSubtitle(_ track: SubtitleTrack, as format: SubtitleFormat) throws -> URL
}

/// 导出服务实现：
/// - 音频导出使用 AVAssetExportSession 的 presetAppleM4A 预设，输出到 Documents/Exports/<标题>.m4a
/// - 字幕导出先应用 SubtitleTrack.timeOffset 再写出，支持 SRT / VTT
/// - @MainActor：导出期间可展示 UI 状态；失败错误为中文 NSError
@MainActor
public final class ExportService: ExportServicing {

    /// 导出目录名（Documents 下）
    public static let exportsDirectoryName = "Exports"

    private let exportsDirectory: URL

    public init(baseURL: URL? = nil) {
        let root = baseURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        exportsDirectory = root.appendingPathComponent(ExportService.exportsDirectoryName, isDirectory: true)
    }

    // MARK: - ExportServicing

    public func exportAudio(from video: VideoItem) async throws -> URL {
        let asset = AVURLAsset(url: video.url)

        // 校验包含音频轨（无音频轨时 M4A 预设也会失败，提前给出明确提示）
        let tracks = (try? await asset.load(.tracks)) ?? []
        guard tracks.contains(where: { $0.mediaType == .audio }) else {
            throw Self.error(code: 2001, message: "「\(video.title)」不包含音频轨，无法导出音频")
        }

        // presetAppleM4A：音频导出预设（常量名 AVAssetExportPresetAppleM4A；
        // 若新版 SDK 更名为 AVOutputSessionPreset.appleM4A，二选一即可）
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw Self.error(code: 2002, message: "当前设备不支持 M4A 音频导出")
        }

        let baseName = Self.sanitizedFileName(video.title)
        let destination = Self.uniqueFileURL(in: exportsDirectory, baseName: baseName, ext: "m4a")
        do {
            try FileManager.default.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
        } catch {
            throw Self.error(code: 2003, message: "导出失败：无法准备输出文件（\(error.localizedDescription)）")
        }

        session.outputURL = destination
        session.outputFileType = .m4a

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
        }

        switch session.status {
        case .completed:
            return destination
        case .cancelled:
            try? FileManager.default.removeItem(at: destination)
            throw Self.error(code: 2004, message: "音频导出已取消")
        default:
            let reason = session.error?.localizedDescription ?? "未知错误"
            try? FileManager.default.removeItem(at: destination)
            throw Self.error(code: 2005, message: "音频导出失败：\(reason)")
        }
    }

    public func exportSubtitle(_ track: SubtitleTrack, as format: SubtitleFormat) throws -> URL {
        let text: String
        let ext: String
        switch format {
        case .srt:
            text = Self.renderSRT(track)
            ext = "srt"
        case .vtt:
            text = Self.renderVTT(track)
            ext = "vtt"
        default:
            throw Self.error(code: 2006, message: "字幕导出仅支持 SRT / VTT 格式")
        }

        let label = track.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = Self.sanitizedFileName(label.isEmpty ? "字幕" : label)
        let destination = Self.uniqueFileURL(in: exportsDirectory, baseName: baseName, ext: ext)
        try FileManager.default.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
        try text.write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }

    // MARK: - 字幕渲染

    /// SRT：序号 + "HH:mm:ss,SSS --> HH:mm:ss,SSS" + 文本（primary/secondary 合并两行）
    private static func renderSRT(_ track: SubtitleTrack) -> String {
        var output = ""
        var index = 1
        for cue in track.cues {
            let start = max(cue.startTime + track.timeOffset, 0)
            let end = max(cue.endTime + track.timeOffset, start)
            let body = Self.cueBody(cue)
            if body.isEmpty { continue }
            output += "\(index)\n"
            output += "\(Self.timestamp(start, millisSeparator: ",")) --> \(Self.timestamp(end, millisSeparator: ","))\n"
            output += body + "\n\n"
            index += 1
        }
        return output
    }

    /// VTT：WEBVTT 头 + 序号 + "HH:mm:ss.SSS --> HH:mm:ss.SSS" + 文本
    private static func renderVTT(_ track: SubtitleTrack) -> String {
        var output = "WEBVTT\n\n"
        var index = 1
        for cue in track.cues {
            let start = max(cue.startTime + track.timeOffset, 0)
            let end = max(cue.endTime + track.timeOffset, start)
            let body = Self.cueBody(cue)
            if body.isEmpty { continue }
            output += "\(index)\n"
            output += "\(Self.timestamp(start, millisSeparator: ".")) --> \(Self.timestamp(end, millisSeparator: "."))\n"
            output += body + "\n\n"
            index += 1
        }
        return output
    }

    /// 主/次字幕合并为两行（次字幕为空时仅一行；整条为空则返回空串并跳过）
    private static func cueBody(_ cue: SubtitleCue) -> String {
        var lines = cue.primaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let secondary = cue.secondaryText?.trimmingCharacters(in: .whitespacesAndNewlines), !secondary.isEmpty {
            lines += "\n" + secondary
        }
        return lines
    }

    /// 时间戳格式化：HH:mm:ss<sep>SSS
    private static func timestamp(_ seconds: TimeInterval, millisSeparator: String) -> String {
        let totalMillis = Int(max(seconds, 0) * 1000)
        let hours = totalMillis / 3_600_000
        let minutes = (totalMillis / 60_000) % 60
        let secs = (totalMillis / 1000) % 60
        let millis = totalMillis % 1000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, secs, millisSeparator, millis)
    }

    // MARK: - 文件命名

    /// 清理文件名中的非法字符（/ : \ ? * " < > | 及控制字符 → "_"）
    private static func sanitizedFileName(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\?*\"<>|").union(.controlCharacters)
        let cleaned = name.components(separatedBy: illegal).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "未命名" : cleaned
    }

    /// 生成不冲突的目标 URL：重名追加 -1 / -2 …
    private static func uniqueFileURL(in directory: URL, baseName: String, ext: String) -> URL {
        var candidate = directory.appendingPathComponent("\(baseName).\(ext)")
        var index = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(index).\(ext)")
            index += 1
        }
        return candidate
    }

    private static func error(code: Int, message: String) -> NSError {
        NSError(domain: "com.parrot.player.export", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
