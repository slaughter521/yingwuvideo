// 文件: NetworkVideoService.swift — 远程直链元信息解析 + 网盘接入抽象（阿里云盘/百度网盘首期为 stub；协议见 ARCHITECTURE.md §4）

import AVFoundation
import Foundation

public protocol NetworkVideoServicing {
    /// 解析远程直链的元信息（时长/大小，HEAD+AVURLAsset）
    func probeRemote(url: URL) async throws -> VideoItem
    /// 网盘接入的抽象（阿里云盘/百度网盘：OAuth + 文件列表 + 直链解析）
    /// 首期实现协议定义 + 阿里云盘 stub（带清晰 TODO），不得阻塞编译
    func cloudProviders() -> [CloudProvider]
}

public protocol CloudProvider: Identifiable {
    var id: String { get }                 // "aliyun"/"baidu"
    var name: String { get }
    var isAuthorized: Bool { get }
    func authorize() async throws
    func listFiles(path: String) async throws -> [CloudFile]
    func playbackURL(for file: CloudFile) async throws -> URL
}

public struct CloudFile: Identifiable, Codable, Sendable {
    public var id: String
    public var name: String
    public var size: Int64?
    public var isFolder: Bool
    public var path: String
}

/// 远程视频服务实现
public final class NetworkVideoService: NetworkVideoServicing, Sendable {

    public init() {}

    // MARK: - NetworkVideoServicing

    public func probeRemote(url: URL) async throws -> VideoItem {
        let scheme = url.scheme?.lowercased() ?? ""
        guard url.isFileURL || scheme == "http" || scheme == "https" else {
            throw Self.error(code: 3001, message: "不支持的链接：仅支持 http/https 视频直链")
        }

        let asset = AVURLAsset(url: url)

        // 异步加载时长与轨道（NaN 保护：非数值/无穷大一律视为未知）
        var duration: TimeInterval?
        if let loaded = try? await asset.load(.duration),
           loaded.isNumeric, loaded.seconds.isFinite, loaded.seconds > 0 {
            duration = loaded.seconds
        }
        let tracks = try? await asset.load(.tracks)
        let hasTracks = (tracks?.isEmpty == false)

        // 时长与轨道都取不到时认为链接无效
        if duration == nil && !hasTracks {
            throw Self.error(code: 3002, message: "无法解析该链接的媒体信息，请确认是有效的视频直链")
        }

        // 文件大小：远程走 HEAD 请求（best-effort），本地直接读属性
        var fileSize: Int64?
        if url.isFileURL {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            fileSize = values?.fileSize.map { Int64($0) }
        } else {
            fileSize = await Self.headContentLength(url: url)
        }

        // 标题：URL 最后一段去扩展名；为空时回退到域名
        let rawName = url.lastPathComponent
        let fallback = url.host ?? "远程视频"
        let name = rawName.isEmpty ? fallback : rawName
        var title = (name as NSString).deletingPathExtension
        if title.isEmpty { title = name }

        return VideoItem(title: title, url: url, kind: .remoteURL,
                         fileSize: fileSize, duration: duration)
    }

    public func cloudProviders() -> [CloudProvider] {
        [AliyunDriveProvider(), BaiduDriveProvider()]
    }

    // MARK: - 私有

    /// HEAD 请求读取 Content-Length（失败返回 nil，不阻塞主流程）
    private static func headContentLength(url: URL) async -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let length = httpResponse.value(forHTTPHeaderField: "Content-Length"),
              let value = Int64(length) else {
            return nil
        }
        return value
    }

    private static func error(code: Int, message: String) -> NSError {
        NSError(domain: "com.parrot.player.network", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - 阿里云盘（首期 stub）

/// 阿里云盘接入（首期 stub：未授权状态，所有网盘操作均抛出中文占位错误）
///
/// 真实实现路径（TODO，授权后替换 stub）：
/// 1. OAuth2 授权码流程：打开授权页
///    https://www.aliyundrive.com/o/authorize?client_id=<client_id>&scope=user:file&redirect_uri=<app scheme>&response_type=code
///    用 ASWebAuthenticationSession 接收回调中的 code
/// 2. POST https://api.aliyundrive.com/oauth/access_token（grant_type=authorization_code）
///    换取 access_token / refresh_token，令牌存入 Keychain 并维护刷新
/// 3. listFiles：POST https://api.aliyundrive.com/adrive/v3/file/list
///    body: { "drive_id": <drive_id>, "parent_file_id": "root", "limit": 100, "marker": <分页> }
///    将返回项映射为 CloudFile（folder 用 type 字段判断）
/// 4. playbackURL：POST https://api.aliyundrive.com/v2/file/get_download_url
///    body: { "file_id": <file.id>, "drive_id": <drive_id> }，取 download_url 作为播放直链
public final class AliyunDriveProvider: CloudProvider, Sendable {

    public let id = "aliyun"
    public let name = "阿里云盘"

    /// stub 阶段始终未授权
    public var isAuthorized: Bool { false }

    public init() {}

    public func authorize() async throws {
        throw AliyunDriveProvider.stubError()
    }

    public func listFiles(path: String) async throws -> [CloudFile] {
        throw AliyunDriveProvider.stubError()
    }

    public func playbackURL(for file: CloudFile) async throws -> URL {
        throw AliyunDriveProvider.stubError()
    }

    static func stubError() -> NSError {
        NSError(domain: "com.parrot.player.network.aliyun", code: 4001,
                userInfo: [NSLocalizedDescriptionKey: "阿里云盘接入需要 OAuth 配置（client_id），当前版本为演示占位"])
    }
}

// MARK: - 百度网盘（首期 stub）

/// 百度网盘接入（首期 stub：未授权状态，所有网盘操作均抛出中文占位错误）
///
/// 真实实现路径（TODO，授权后替换 stub）：
/// 1. OAuth2 授权码流程：https://openapi.baidu.com/oauth/2.0/authorize?...&response_type=code
///    → ASWebAuthenticationSession 接收 code → POST https://openapi.baidu.com/oauth/2.0/token
///    换取 access_token / refresh_token，令牌存入 Keychain
/// 2. listFiles：GET https://pan.baidu.com/rest/2.0/xpan/file?method=list&dir=<path>&access_token=<token>
///    返回 list 数组，映射为 CloudFile（isdir 判断 folder）
/// 3. playbackURL：GET https://pan.baidu.com/rest/2.0/xpan/file?method=streaming?path=<path>&access_token=<token>
///    返回 302 重定向至 dlink 直链，跟随重定向拿到最终播放 URL
public final class BaiduDriveProvider: CloudProvider, Sendable {

    public let id = "baidu"
    public let name = "百度网盘"

    /// stub 阶段始终未授权
    public var isAuthorized: Bool { false }

    public init() {}

    public func authorize() async throws {
        throw BaiduDriveProvider.stubError()
    }

    public func listFiles(path: String) async throws -> [CloudFile] {
        throw BaiduDriveProvider.stubError()
    }

    public func playbackURL(for file: CloudFile) async throws -> URL {
        throw BaiduDriveProvider.stubError()
    }

    static func stubError() -> NSError {
        NSError(domain: "com.parrot.player.network.baidu", code: 4001,
                userInfo: [NSLocalizedDescriptionKey: "百度网盘接入需要 OAuth 配置（client_id），当前版本为演示占位"])
    }
}
