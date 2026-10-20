// 文件: SubtitleParser.swift — 字幕解析服务
// 职责：实现 SubtitleParsing 协议，支持 SRT / ASS(SSA) / VTT / LRC 四种字幕格式的
//       自动识别与解析；处理多编码兼容（UTF-8 / UTF-16 / GBK）、双语字幕拆分与
//       双轨时间轴合并。解析器对空文件与坏行统一抛出 SubtitleParseError，绝不崩溃。
import Foundation

// MARK: - 服务协议（ARCHITECTURE.md §4 逐字定义，禁止修改）

public protocol SubtitleParsing {
    /// 从本地字幕文件解析；自动识别格式（SRT/ASS/VTT/LRC）
    func parse(fileURL: URL) throws -> SubtitleTrack
    /// 从文本内容解析（需显式指定格式）
    func parse(content: String, format: SubtitleFormat) throws -> SubtitleTrack
    /// 双语合并：primary 为主字幕，secondary 为译文字幕，按时间轴对齐（容差 ±0.5s，找不到匹配则留空）
    func mergeBilingual(primary: SubtitleTrack, secondary: SubtitleTrack) -> SubtitleTrack
}

// MARK: - 解析错误（中文提示）

public enum SubtitleParseError: Error, LocalizedError {
    case unsupportedFormat
    case emptyContent
    case malformedLine(String)
    case fileNotReadable(URL)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "无法识别的字幕格式（仅支持 SRT / ASS / SSA / VTT / LRC）"
        case .emptyContent:
            return "字幕内容为空"
        case .malformedLine(let line):
            return "字幕文件存在无法解析的内容：\(line)"
        case .fileNotReadable(let url):
            return "无法读取字幕文件：\(url.lastPathComponent)"
        }
    }
}

// MARK: - 解析器实现

public final class SubtitleParser: SubtitleParsing {

    /// 双语合并容差（秒）：secondary cue 起始时间与 primary 相差不超过该值即视为匹配
    public static let mergeTolerance: TimeInterval = 0.5

    /// LRC 最后一条歌词的兜底展示时长（秒）
    private static let lrcFallbackDuration: TimeInterval = 5

    public init() {}

    // MARK: 文件解析

    public func parse(fileURL: URL) throws -> SubtitleTrack {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SubtitleParseError.fileNotReadable(fileURL)
        }
        let content = try Self.readText(from: fileURL)
        let format = Self.sniffFormat(content: content, fileExtension: fileURL.pathExtension)
        guard format != .unknown else { throw SubtitleParseError.unsupportedFormat }
        return try parse(content: content, format: format)
    }

    // MARK: 文本解析

    public func parse(content: String, format: SubtitleFormat) throws -> SubtitleTrack {
        // 统一换行符 + 去 BOM
        var text = content.replacingOccurrences(of: "\u{FEFF}", with: "")
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SubtitleParseError.emptyContent
        }

        switch format {
        case .srt: return try parseSRT(text)
        case .ass: return try parseASS(text)
        case .vtt: return try parseVTT(text)
        case .lrc: return try parseLRC(text)
        case .unknown: throw SubtitleParseError.unsupportedFormat
        }
    }

    // MARK: 双语合并

    public func mergeBilingual(primary: SubtitleTrack, secondary: SubtitleTrack) -> SubtitleTrack {
        let sortedSecondary = secondary.cues.sorted { $0.startTime < $1.startTime }
        var merged: [SubtitleCue] = []
        merged.reserveCapacity(primary.cues.count)

        for cue in primary.cues {
            // 寻找起始时间最接近且差值在容差内的 secondary cue
            var best: SubtitleCue?
            var bestDelta = Double.greatestFiniteMagnitude
            for sc in sortedSecondary {
                let delta = abs(sc.startTime - cue.startTime)
                if delta < bestDelta {
                    bestDelta = delta
                    best = sc
                }
                // secondary 已按起始时间升序，超过容差上限后无需继续
                if sc.startTime > cue.startTime + Self.mergeTolerance { break }
            }
            let secondaryText: String?
            if let best = best, bestDelta <= Self.mergeTolerance {
                secondaryText = best.primaryText
            } else {
                secondaryText = nil
            }
            merged.append(SubtitleCue(startTime: cue.startTime,
                                      endTime: cue.endTime,
                                      primaryText: cue.primaryText,
                                      secondaryText: secondaryText))
        }
        return SubtitleTrack(label: primary.label,
                             format: primary.format,
                             language: primary.language,
                             cues: merged,
                             timeOffset: primary.timeOffset)
    }

    // MARK: - SRT 解析

    private func parseSRT(_ text: String) throws -> SubtitleTrack {
        let lines = Self.splitLines(text)
        var cues: [SubtitleCue] = []
        var index = 0

        while index < lines.count {
            // 跳过块间空行
            if lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }
            let blockStart = lines[index].trimmingCharacters(in: .whitespaces)
            var timingLine: String?
            if Int(blockStart) != nil {
                // 标准 SRT：序号行 + 时间行
                index += 1
                if index < lines.count { timingLine = lines[index] }
            } else {
                // 宽容无序号 SRT：当前行即时间行
                timingLine = lines[index]
            }
            guard let timing = timingLine,
                  let times = Self.parseTimingLine(timing) else {
                // timingLine 为 nil（序号行后即文件尾）时退回块首行，保证不越界
                let offending = timingLine ?? lines[min(index, lines.count - 1)]
                throw SubtitleParseError.malformedLine(offending)
            }
            index += 1

            // 文本行直到空行/文件尾（可能多行，保留 \n）
            var textLines: [String] = []
            while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                textLines.append(lines[index])
                index += 1
            }
            let rawText = textLines.joined(separator: "\n")
            let (primary, secondary) = Self.splitBilingualLines(rawText)
            if !primary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cues.append(SubtitleCue(startTime: times.start,
                                        endTime: max(times.end, times.start),
                                        primaryText: primary,
                                        secondaryText: secondary))
            }
        }
        guard !cues.isEmpty else { throw SubtitleParseError.emptyContent }
        return SubtitleTrack(label: "外挂字幕", format: .srt,
                             language: Self.languageFor(cues), cues: cues)
    }

    // MARK: - ASS / SSA 解析

    private func parseASS(_ text: String) throws -> SubtitleTrack {
        let lines = Self.splitLines(text)
        // ASS 默认字段顺序
        var formatFields = ["Layer", "Start", "End", "Style", "Name",
                            "MarginL", "MarginR", "MarginV", "Effect", "Text"]
        var inEvents = false
        var cues: [SubtitleCue] = []

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // 段头切换（[Script Info] / [V4+ Styles] / [Events] / [Fonts] …）
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inEvents = (line.lowercased() == "[events]")
                continue
            }
            guard inEvents else { continue }

            let lower = line.lowercased()
            if lower.hasPrefix("format:") {
                let value = String(line.dropFirst("format:".count)).trimmingCharacters(in: .whitespaces)
                let fields = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if fields.count >= 5 { formatFields = fields }
                continue
            }
            guard lower.hasPrefix("dialogue:") else { continue }   // Comment: 等直接跳过

            let payload = String(line.dropFirst("dialogue:".count))
            // 按逗号切分；最后一段（Text）可能含逗号，需拼回
            let commaParts = payload.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let fieldCount = formatFields.count
            guard commaParts.count >= fieldCount else {
                throw SubtitleParseError.malformedLine(rawLine)
            }
            var dict: [String: String] = [:]
            for i in 0..<fieldCount {
                let field = formatFields[i]
                if i == fieldCount - 1 {
                    dict[field] = commaParts[i...].joined(separator: ",")
                } else {
                    dict[field] = commaParts[i].trimmingCharacters(in: .whitespaces)
                }
            }
            // 字段名大小写容错匹配
            func field(_ name: String) -> String? {
                dict.first { $0.key.compare(name, options: .caseInsensitive) == .orderedSame }?.value
            }
            guard let startStr = field("Start"), let endStr = field("End"),
                  let start = Self.parseTimestamp(startStr),
                  let end = Self.parseTimestamp(endStr) else {
                throw SubtitleParseError.malformedLine(rawLine)
            }
            let cleaned = Self.cleanASSText(field("Text") ?? "")
            let (primary, secondary) = Self.splitBilingualLines(cleaned)
            if !primary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cues.append(SubtitleCue(startTime: start,
                                        endTime: max(end, start),
                                        primaryText: primary,
                                        secondaryText: secondary))
            }
        }
        guard !cues.isEmpty else { throw SubtitleParseError.emptyContent }
        return SubtitleTrack(label: "外挂字幕", format: .ass,
                             language: Self.languageFor(cues), cues: cues)
    }

    // MARK: - VTT 解析

    private func parseVTT(_ text: String) throws -> SubtitleTrack {
        let lines = Self.splitLines(text)
        var cues: [SubtitleCue] = []
        var index = 0

        // 跳过 WEBVTT 文件头（头之后到首个 cue 之前的 NOTE/STYLE/REGION 元数据）
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { index += 1; continue }
            if line.hasPrefix("WEBVTT") { index += 1; continue }
            break
        }

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)

            // NOTE / STYLE / REGION 块：整块跳过（直到空行）
            let upper = trimmed.uppercased()
            if upper.hasPrefix("NOTE") || upper.hasPrefix("STYLE") || upper.hasPrefix("REGION") {
                index += 1
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    index += 1
                }
                continue
            }
            if trimmed.isEmpty { index += 1; continue }

            // 当前行是时间行，否则视为 cue 标识行，取下一行
            var timing: (start: TimeInterval, end: TimeInterval)? = Self.parseTimingLine(lines[index])
            if timing == nil {
                index += 1
                guard index < lines.count else { break }
                timing = Self.parseTimingLine(lines[index])
            }
            guard let times = timing else {
                throw SubtitleParseError.malformedLine(lines[min(index, lines.count - 1)])
            }
            index += 1

            var textLines: [String] = []
            while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                textLines.append(lines[index])
                index += 1
            }
            let cleaned = Self.cleanVTTTags(textLines.joined(separator: "\n"))
            let (primary, secondary) = Self.splitBilingualLines(cleaned)
            if !primary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cues.append(SubtitleCue(startTime: times.start,
                                        endTime: max(times.end, times.start),
                                        primaryText: primary,
                                        secondaryText: secondary))
            }
        }
        guard !cues.isEmpty else { throw SubtitleParseError.emptyContent }
        return SubtitleTrack(label: "外挂字幕", format: .vtt,
                             language: Self.languageFor(cues), cues: cues)
    }

    // MARK: - LRC 解析

    private func parseLRC(_ text: String) throws -> SubtitleTrack {
        // 时间标签（行首可多个）：[mm:ss.xx] / [mm:ss:xx] / [mm:ss.xxx] / [h:mm:ss.xx]
        let timeTagPattern = #"^\[(\d{1,3}):(\d{1,2})([.:]\d{1,3})?\]"#
        // ID 标签：[ar:歌手] [offset:500] [ti:标题] 等（非时间），整体跳过
        let idTagPattern = #"^\[[A-Za-z][^:]*:[^\]]*\]"#

        var entries: [(time: TimeInterval, text: String)] = []
        var lrcOffset: TimeInterval = 0   // [offset:+500] 毫秒级整体平移

        for rawLine in Self.splitLines(text) {
            var rest = rawLine
            var times: [TimeInterval] = []
            while let match = rest.range(of: timeTagPattern, options: .regularExpression) {
                let tag = String(rest[match])
                if let t = Self.parseTimestamp(tag.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) {
                    times.append(t)
                }
                rest = String(rest[match.upperBound...])
            }

            let lyric = rest.trimmingCharacters(in: .whitespaces)
            if times.isEmpty {
                // 无时间标签：可能是 [offset:±ms] 等 ID 标签，解析后跳过
                if let idMatch = rawLine.range(of: idTagPattern, options: .regularExpression) {
                    let idTag = String(rawLine[idMatch]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    let kv = idTag.split(separator: ":", maxSplits: 1).map(String.init)
                    if kv.count == 2, kv[0].lowercased() == "offset", let ms = Double(kv[1]) {
                        lrcOffset = ms / 1000.0
                    }
                }
                continue
            }
            guard !lyric.isEmpty else { continue }   // 空歌词时间标签无展示意义
            for t in times {
                entries.append((t + lrcOffset, lyric))
            }
        }
        guard !entries.isEmpty else { throw SubtitleParseError.emptyContent }
        entries.sort { $0.time < $1.time }

        var cues: [SubtitleCue] = []
        for (i, entry) in entries.enumerated() {
            // endTime 取下一行起始时间；末条用兜底时长
            let end: TimeInterval
            if i + 1 < entries.count {
                end = max(entries[i + 1].time, entry.time)
            } else {
                end = entry.time + Self.lrcFallbackDuration
            }
            cues.append(SubtitleCue(startTime: entry.time, endTime: end,
                                    primaryText: entry.text, secondaryText: nil))
        }
        return SubtitleTrack(label: "歌词字幕", format: .lrc,
                             language: Self.languageFor(cues), cues: cues)
    }

    // MARK: - 编码兼容读取

    /// 多编码兼容读取：UTF-16 BOM → UTF-8 BOM → UTF-8 → UTF-16(无BOM) → GB18030(GBK)
    static func readText(from url: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SubtitleParseError.fileNotReadable(url)
        }
        return try decode(data: data, url: url)
    }

    static func decode(data: Data, url: URL) throws -> String {
        if data.isEmpty { throw SubtitleParseError.emptyContent }

        if data.starts(with: [0xFF, 0xFE]), let s = String(data: data, encoding: .utf16LittleEndian) { return s }
        if data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16BigEndian) { return s }
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let s = String(data: data, encoding: .utf8) { return s }

        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .utf16LittleEndian) { return s }
        if let s = String(data: data, encoding: gb18030) { return s }
        throw SubtitleParseError.fileNotReadable(url)
    }

    /// GB18030（含 GBK）编码，用于兼容国内老字幕文件
    static let gb18030: String.Encoding = {
        let cfEnc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(kCFStringEncodingGB_18030_2000))
        return String.Encoding(rawValue: cfEnc.rawValue)
    }()

    // MARK: - 格式嗅探

    /// 扩展名优先，其次内容嗅探（ASS > VTT > SRT > LRC）
    static func sniffFormat(content: String, fileExtension: String? = nil) -> SubtitleFormat {
        if let ext = fileExtension?.lowercased() {
            switch ext {
            case "srt": return .srt
            case "ass", "ssa": return .ass
            case "vtt": return .vtt
            case "lrc": return .lrc
            default: break
            }
        }
        let head = String(content.prefix(4096))
        // ASS：段落标记或对白行
        if head.contains("[Events]") || head.contains("Dialogue:") || head.contains("Format: Layer") {
            return .ass
        }
        if head.contains("WEBVTT") { return .vtt }
        if head.contains("-->") {
            // SRT 毫秒用逗号，VTT 用点
            if head.range(of: #"\d{2}:\d{2}:\d{2},\d{3}"#, options: .regularExpression) != nil {
                return .srt
            }
            return .vtt
        }
        // LRC：行首时间标签
        if head.range(of: #"(?m)^\[\d{1,3}:\d{1,2}([.:]\d{1,3})?\]"#, options: .regularExpression) != nil {
            return .lrc
        }
        return .unknown
    }

    // MARK: - 时间戳解析（毫秒级精度）

    /// 解析 "HH:mm:ss,SSS" / "HH:mm:ss.SSS" / "H:MM:SS.cc"(ASS 厘秒) / "MM:SS.mmm"
    /// 小数位 1~3 位按比例补全毫秒，4 位以上截断到毫秒
    static func parseTimestamp(_ raw: String) -> TimeInterval? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        let colonParts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard colonParts.count == 2 || colonParts.count == 3 else { return nil }

        var hours: Double = 0
        var minutes: Double
        var secondsPart: String
        if colonParts.count == 3 {
            guard let h = Double(String(colonParts[0])) else { return nil }
            hours = h
            guard let m = Double(String(colonParts[1])) else { return nil }
            minutes = m
            secondsPart = String(colonParts[2])
        } else {
            guard let m = Double(String(colonParts[0])) else { return nil }
            minutes = m
            secondsPart = String(colonParts[1])
        }

        // 秒与小数部分（逗号或点分隔）
        let secParts = secondsPart.split(whereSeparator: { $0 == "." || $0 == "," })
        guard let sec = Double(secParts.first.map(String.init) ?? "") else { return nil }
        var fraction: Double = 0
        if secParts.count > 1, let fracStr = secParts.last {
            let padded = fracStr.count >= 3 ? String(fracStr.prefix(3))
                                            : fracStr.padding(toLength: 3, withPad: "0", startingAt: 0)
            if let ms = Double(padded) { fraction = ms / 1000.0 }
        }
        return hours * 3600 + minutes * 60 + sec + fraction
    }

    /// 解析时间行 "start --> end"（VTT 行尾可能附带 line/position 等设置）
    static func parseTimingLine(_ line: String) -> (start: TimeInterval, end: TimeInterval)? {
        let components = line.components(separatedBy: "-->")
        guard components.count >= 2 else { return nil }
        let startStr = components[0].trimmingCharacters(in: .whitespaces)
        // 结束时间只取第一个空白符之前的部分（其后为 cue 设置）
        let endStr = components[1].trimmingCharacters(in: .whitespaces)
        let endToken = endStr.split(separator: " ").first.map(String.init) ?? endStr
        guard let start = parseTimestamp(startStr), let end = parseTimestamp(endToken) else { return nil }
        return (start, end)
    }

    // MARK: - 文本清洗

    /// 清除 ASS 覆盖标签 {\an8} 与 \N \n \h 换行控制
    static func cleanASSText(_ raw: String) -> String {
        // 1. 移除 {...} 覆盖块（含 \an8 \pos \fad \c&H..& 等）
        var result = ""
        var depth = 0
        for ch in raw {
            if ch == "{" { depth += 1; continue }
            if ch == "}" { if depth > 0 { depth -= 1 }; continue }
            if depth == 0 { result.append(ch) }
        }
        // 2. 行内换行 / 硬空格控制
        result = result.replacingOccurrences(of: "\\N", with: "\n")
        result = result.replacingOccurrences(of: "\\n", with: "\n")
        result = result.replacingOccurrences(of: "\\h", with: " ")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 清除 VTT 标签（<v Speaker> <i> <b> <c.class> <00:00:01.000> <lang en>）与常见实体
    static func cleanVTTTags(_ raw: String) -> String {
        var result = raw
        if result.range(of: #"</?[^<>]*>"#, options: .regularExpression) != nil {
            result = result.replacingOccurrences(of: #"</?[^<>]*>"#, with: "", options: .regularExpression)
        }
        result = result.replacingOccurrences(of: "&amp;", with: "&")
                     .replacingOccurrences(of: "&lt;", with: "<")
                     .replacingOccurrences(of: "&gt;", with: ">")
                     .replacingOccurrences(of: "&nbsp;", with: " ")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 双语 SRT 拆分：多行文本中以中文（CJK）为主的行归为译文，其余归主字幕
    static func splitBilingualLines(_ raw: String) -> (primary: String, secondary: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2 else { return (trimmed, nil) }

        var primaryLines: [String] = []
        var secondaryLines: [String] = []
        for line in lines {
            if isDominantlyCJK(line) {
                secondaryLines.append(line)
            } else {
                primaryLines.append(line)
            }
        }
        if secondaryLines.isEmpty {
            return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }
        return (primaryLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                secondaryLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 判断文本是否以中文/日文（CJK 及假名）为主：CJK 类字符占字母类字符比例 ≥ 50%
    static func isDominantlyCJK(_ text: String) -> Bool {
        var cjk = 0
        var letters = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF,     // CJK 统一表意符号
             0x3400...0x4DBF,         // 扩展 A
             0x20000...0x2A6DF,       // 扩展 B
             0xF900...0xFAFF,         // 兼容表意文字
             0x3000...0x303F,         // CJK 标点
             0x3040...0x30FF,         // 日文平假名/片假名
             0x31F0...0x31FF:         // 片假名音标扩展
                cjk += 1
                letters += 1
            default:
                if scalar.properties.isAlphabetic { letters += 1 }
            }
        }
        return letters > 0 && Double(cjk) / Double(letters) >= 0.5
    }

    /// 依据主字幕样本推断语言标签（BCP-47）
    static func languageFor(_ cues: [SubtitleCue]) -> String {
        guard !cues.isEmpty else { return "en" }
        let sample = cues.prefix(20)
        var cjkCount = 0
        for cue in sample where isDominantlyCJK(cue.primaryText) { cjkCount += 1 }
        return cjkCount > sample.count / 2 ? "zh-Hans" : "en"
    }

    // MARK: - 工具

    /// 统一换行后按行切分（保留空行结构）
    static func splitLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}
