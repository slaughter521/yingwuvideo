// 文件: LibraryService.swift — 媒体库文件管理服务：本地视频扫描、文件导入、字幕匹配、缩略图生成与删除（协议见 ARCHITECTURE.md §4）

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

public protocol LibraryServicing {
    /// 扫描 Documents 目录中的视频文件（mp4/mkv/mov/avi/m4v/flv/wmv/ts/webm…）
    func scanLocalVideos() throws -> [VideoItem]
    /// 通过 iTunes 文件共享/文件 App 导入的文件（同一目录，按需分类）
    func importFromSharedContainer() throws -> [VideoItem]
    /// 自动匹配同名字幕（.srt/.ass/.vtt，与视频同目录同名）
    func matchSubtitle(for video: VideoItem) -> URL?
    /// 生成并缓存视频缩略图，返回相对路径
    func generateThumbnail(for video: VideoItem) async throws -> String
    /// 删除本地视频文件
    func delete(_ video: VideoItem) throws
    /// 解析远程直链的元信息（时长/大小），由 LibraryViewModel.addRemoteURL 调用
    func probeRemote(url: URL) async throws -> VideoItem
}

/// 媒体库服务实现：
/// - 视频/音频统一存放于 Documents/ParrotPlayerVideos/（mp3/m4a 一并收录，供导出演示）
/// - 缩略图缓存于 Documents/Thumbnails/；VideoItem.thumbnailPath 记录相对 Documents 的路径
/// - 文件操作为同步 IO，由调用方（@MainActor ViewModel）在合适时机调用
public final class LibraryService: LibraryServicing, Sendable {

    /// 视频/音频统一存放目录名（Documents 下）
    public static let videosDirectoryName = "ParrotPlayerVideos"
    /// 缩略图缓存目录名（Documents 下）
    public static let thumbnailsDirectoryName = "Thumbnails"

    /// 支持的媒体扩展名（视频 + 音频；音频收进来仅供导出演示）
    public static let supportedExtensions: Set<String> = [
        "mp4", "mkv", "mov", "m4v", "avi", "flv", "wmv", "ts", "webm", "rmvb", "3gp",
        "mp3", "m4a"
    ]

    /// 支持自动匹配的外挂字幕扩展名
    public static let subtitleExtensions: [String] = ["srt", "ass", "vtt", "lrc"]

    private let documentsURL: URL
    private let videosDirectory: URL
    private let thumbnailsDirectory: URL

    /// - Parameter baseURL: 沙盒根目录；默认使用 App Documents 目录（测试时可注入）
    public init(baseURL: URL? = nil) {
        let root = baseURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        documentsURL = root
        videosDirectory = root.appendingPathComponent(LibraryService.videosDirectoryName, isDirectory: true)
        thumbnailsDirectory = root.appendingPathComponent(LibraryService.thumbnailsDirectoryName, isDirectory: true)
    }

    // MARK: - LibraryServicing

    public func scanLocalVideos() throws -> [VideoItem] {
        // 扫描 Documents/ParrotPlayerVideos/ 与 Documents 根目录，去重后按添加时间倒序
        let scanned = try items(in: videosDirectory) + items(in: documentsURL)
        var seen = Set<URL>()
        var result: [VideoItem] = []
        for item in scanned where !seen.contains(item.url) {
            seen.insert(item.url)
            result.append(item)
        }
        return result.sorted { $0.dateAdded > $1.dateAdded }
    }

    public func importFromSharedContainer() throws -> [VideoItem] {
        // 文件 App / iTunes 共享放置于 Documents 根目录（浅层扫描，不含子目录）
        try items(in: documentsURL).sorted { $0.dateAdded > $1.dateAdded }
    }

    public func matchSubtitle(for video: VideoItem) -> URL? {
        // 同目录同主名：video.mp4 → video.srt / video.ass / video.vtt / video.lrc
        let base = video.url.deletingPathExtension()
        for ext in LibraryService.subtitleExtensions {
            let candidate = base.appendingPathExtension(ext)
            if video.url.isFileURL, FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    public func generateThumbnail(for video: VideoItem) async throws -> String {
        guard let path = await generateThumbnailIfAvailable(for: video) else {
            throw Self.error(code: 1005, message: "无法生成封面图：该媒体可能已损坏或格式不受支持")
        }
        return path
    }

    public func delete(_ video: VideoItem) throws {
        // 删除本地视频文件（远程项无本地文件，仅清理缓存）
        if video.url.isFileURL, FileManager.default.fileExists(atPath: video.url.path) {
            do {
                try FileManager.default.removeItem(at: video.url)
            } catch {
                throw Self.error(code: 1004, message: "删除视频文件失败：\(error.localizedDescription)")
            }
        }
        // 同步删除缓存的缩略图
        if let relative = video.thumbnailPath,
           let thumbnailFileURL = thumbnailURL(forRelativePath: relative),
           FileManager.default.fileExists(atPath: thumbnailFileURL.path) {
            try? FileManager.default.removeItem(at: thumbnailFileURL)
        }
    }

    // MARK: - 协议外补充方法

    /// 将 VideoItem.thumbnailPath（相对 Documents 的路径）解析为完整 URL；
    /// 兼容历史绝对路径数据；路径无效时返回 nil。
    public func thumbnailURL(forRelativePath path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") {
            // 兼容早期存了绝对路径的数据
            return URL(fileURLWithPath: path)
        }
        return documentsURL.appendingPathComponent(path)
    }

    /// 生成缩略图的容错版本：失败返回 nil 而不抛出（供批量补封面等场景使用）
    public func generateThumbnailIfAvailable(for video: VideoItem) async -> String? {
        let asset = AVURLAsset(url: video.url)

        // 抓帧时刻：时长的 10% 处；时长未知时取 1s
        var captureSeconds: TimeInterval = 1.0
        if let duration = try? await asset.load(.duration),
           duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 {
            captureSeconds = max(duration.seconds * 0.1, 0.1)
        }
        let time = CMTime(seconds: captureSeconds, preferredTimescale: 600)

        guard let cgImage = await Self.cgImage(asset: asset, at: time) else { return nil }

        do {
            try FileManager.default.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
            let fileName = video.id.uuidString + ".jpg"
            let fileURL = thumbnailsDirectory.appendingPathComponent(fileName)
            guard Self.writeJPEG(cgImage: cgImage, quality: 0.8, to: fileURL) else { return nil }
            // 返回相对 Documents 的路径，如 "Thumbnails/<uuid>.jpg"
            return LibraryService.thumbnailsDirectoryName + "/" + fileName
        } catch {
            return nil
        }
    }

    // MARK: - 私有实现

    /// 浅层扫描指定目录中的媒体文件
    private func items(in directory: URL) throws -> [VideoItem] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey],
            options: .skipsHiddenFiles
        )
        var result: [VideoItem] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey])
            if values?.isDirectory == true { continue }
            guard LibraryService.supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let size = values?.fileSize.map { Int64($0) }
            let date = values?.creationDate ?? Date()
            // title 去扩展名
            let title = url.deletingPathExtension().lastPathComponent
            result.append(VideoItem(title: title, url: url, kind: .local, fileSize: size, dateAdded: date))
        }
        return result
    }

    /// 通过 AVAssetImageGenerator 抓帧（用 iOS 4 起的回调 API 包装为 async，保证部署目标兼容）
    private static func cgImage(asset: AVAsset, at time: CMTime) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return await withCheckedContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, result, error in
                // 单次请求只回调一次；失败/取消时返回 nil
                if error == nil, result == .succeeded, let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// 将 CGImage 以 JPEG（质量 0.8）写入目标 URL（ImageIO 实现，避免引入 UIKit）
    private static func writeJPEG(cgImage: CGImage, quality: Double, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            return false
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    private static func error(code: Int, message: String) -> NSError {
        NSError(domain: "com.parrot.player.library", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - 导入（协议外补充方法）

extension LibraryService {
    /// 解析远程直链元信息（协议要求）：实际探测逻辑在 NetworkVideoService 中，此处转发
    public func probeRemote(url: URL) async throws -> VideoItem {
        try await NetworkVideoService().probeRemote(url: url)
    }

    /// 将外部文件（文件 App / iTunes 共享 / 拖入）拷贝到 Documents/ParrotPlayerVideos/
    /// - 重名文件自动追加 -1/-2 后缀
    /// - 自动处理安全作用域资源（startAccessingSecurityScopedResource）
    public func importVideo(from sourceURL: URL) throws -> VideoItem {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

        let fileManager = FileManager.default
        guard sourceURL.isFileURL, fileManager.fileExists(atPath: sourceURL.path) else {
            throw Self.error(code: 1002, message: "导入失败：找不到文件「\(sourceURL.lastPathComponent)」")
        }
        do {
            try fileManager.createDirectory(at: videosDirectory, withIntermediateDirectories: true)
        } catch {
            throw Self.error(code: 1001, message: "导入失败：无法创建视频目录")
        }

        let ext = sourceURL.pathExtension
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        var destination = videosDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        var index = 1
        // 重名追加 -1 / -2 …
        while fileManager.fileExists(atPath: destination.path) {
            destination = videosDirectory.appendingPathComponent("\(baseName)-\(index).\(ext)")
            index += 1
        }

        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
        } catch {
            throw Self.error(code: 1003, message: "导入失败：拷贝文件时出错（\(error.localizedDescription)）")
        }

        let values = try? destination.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
        return VideoItem(title: baseName,
                         url: destination,
                         kind: .local,
                         fileSize: values?.fileSize.map { Int64($0) },
                         dateAdded: values?.creationDate ?? Date())
    }
}
