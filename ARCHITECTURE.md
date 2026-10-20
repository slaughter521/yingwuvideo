# 鹦鹉播放器 (ParrotPlayer) — 架构设计文档

> 模仿「小鹦看看」的 iOS 视频播放器（外语学习向）。本文件是所有并行开发任务的**统一契约**：
> 数据模型、协议、命名必须严格遵守，任何模块不得擅自更改公共接口。

## 1. 项目概况

- **产品名**：鹦鹉播放器 / ParrotPlayer
- **平台**：iOS 16.0+ / iPadOS 16.0+（SwiftUI + AVKit + AVFoundation）
- **包名**：`com.parrot.player`
- **工程生成**：XcodeGen（`project.yml` → `xcodegen generate` 生成 `.xcodeproj`）
- **架构**：SwiftUI + MVVM；ObservableObject ViewModel + 服务层协议化
- **持久化**：JSON 文件存储（App Group 容器目录），不依赖 SwiftData（降低耦合）

## 2. 目录结构（所有文件必须放对位置）

```
鹦鹉播放器/
├── ARCHITECTURE.md            # 本文档
├── project.yml                # XcodeGen 配置
├── README.md                  # 交付说明（最后写）
├── web-demo/                  # Web 高仿演示版（独立子任务）
│   ├── index.html
│   ├── app.js
│   └── styles.css
└── ParrotPlayer/              # Xcode 源码目录
    ├── Info.plist
    ├── ParrotPlayerApp.swift              # App 入口（@main）
    ├── RootView.swift                      # Tab 根视图
    ├── Models/                             # 数据模型（§3 定义，禁止改动字段）
    │   ├── VideoItem.swift
    │   ├── SubtitleModels.swift
    │   ├── StudyModels.swift
    │   ├── AppSettings.swift
    │   └── PlaybackModels.swift
    ├── Services/                           # 服务层（协议见 §4）
    │   ├── StorageService.swift            # JSON 持久化（agent-skeleton 负责）
    │   ├── SubtitleParser.swift            # SRT/ASS/VTT/LRC 解析（agent-subtitle 负责）
    │   ├── SubtitleSynchronizer.swift      # 时间轴调整/合并（agent-subtitle 负责）
    │   ├── VocabularyAnalyzer.swift        # 词汇分析（agent-subtitle 负责）
    │   ├── DictionaryService.swift         # 词典服务（agent-subtitle 负责）
    │   ├── HistoryStore.swift              # 播放历史/断点续播（agent-library 负责）
    │   ├ LibraryService.swift              # 媒体库文件管理（agent-library 负责）
    │   ├── NetworkVideoService.swift       # 远程 URL/网盘（agent-library 负责）
    │   └── ExportService.swift             # 音频/字幕导出（agent-library 负责）
    ├── ViewModels/
    │   ├── PlayerViewModel.swift           # 播放器 VM（agent-player 负责，API 见 §5）
    │   ├── LibraryViewModel.swift          # 媒体库 VM（agent-library 负责）
    │   ├── StudyViewModel.swift            # 学习 VM（agent-study 负责）
    │   └── SettingsViewModel.swift         # 设置 VM（agent-library 负责）
    ├── Views/
    │   ├── Library/                        # 媒体库页面（agent-library）
    │   │   ├── LibraryView.swift
    │   │   ├── VideoRowView.swift
    │   │   ├── AddURLSheet.swift
    │   │   └── PosterWallView.swift
    │   ├── Player/                         # 播放器页面（agent-player）
    │   │   ├── PlayerView.swift
    │   │   ├── PlayerControlsView.swift
    │   │   ├── GestureOverlayView.swift
    │   │   ├── SubtitleDisplayView.swift   # 复用字幕渲染（agent-subtitle 提供组件）
    │   │   ├── SpeedControlView.swift
    │   │   ├── ABLoopPanel.swift
    │   │   └── PlaylistDrawerView.swift
    │   ├── Study/                          # 学习页面（agent-study）
    │   │   ├── StudyView.swift
    │   │   ├── WordBookView.swift
    │   │   ├── SentenceFavoritesView.swift
    │   │   ├── NotesView.swift
    │   │   ├── WordDetailSheet.swift
    │   │   ├── VocabularyReportView.swift
    │   │   └── ShadowingPracticeView.swift
    │   ├── Settings/                       # 设置页面（agent-library）
    │   │   └── SettingsView.swift
    │   └── Components/                     # 通用组件（谁需要谁建，保持通用）
    │       └── (EmptyStateView, ToastView 等)
    └── Resources/
        ├── Assets.xcassets/                # 占位（XcodeGen 生成，agent-skeleton 建目录+Contents.json）
        ├── Vocabulary/
        │   └── cet4_words.txt               # 四级词库（每行一个词，agent-subtitle 生成）
        └── Localizable 暂不需要（中文界面为主）
```

## 3. 数据模型定义（**逐字使用，禁止修改字段名/类型**）

### Models/VideoItem.swift
```swift
import Foundation

/// 媒体来源类型
public enum VideoSourceKind: String, Codable, CaseIterable, Sendable {
    case local          // App 沙盒/Documents
    case remoteURL      // 远程直链(http/https)
    case networkShare   // SMB/FTP/WebDAV/NFS（预留）
    case cloudDrive     // 网盘（阿里云盘/百度网盘，预留）
    case ted            // 内置 TED 资源（预留）
}

public struct VideoItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var title: String
    public var url: URL                 // 本地 fileURL 或远程 URL
    public var kind: VideoSourceKind
    public var fileSize: Int64?         // 字节
    public var duration: TimeInterval?  // 秒
    public var thumbnailPath: String?   // 本地缓存的封面相对路径
    public var subtitlePath: String?    // 匹配到的外挂字幕本地路径
    public var dateAdded: Date
    public var lastPlayed: Date?
    public var isFavorite: Bool = false
    // 断点续播
    public var resumePosition: TimeInterval = 0

    public init(title: String, url: URL, kind: VideoSourceKind, fileSize: Int64? = nil,
                duration: TimeInterval? = nil, thumbnailPath: String? = nil,
                subtitlePath: String? = nil, dateAdded: Date = Date()) {
        self.title = title; self.url = url; self.kind = kind
        self.fileSize = fileSize; self.duration = duration
        self.thumbnailPath = thumbnailPath; self.subtitlePath = subtitlePath
        self.dateAdded = dateAdded
    }
}
```

### Models/SubtitleModels.swift
```swift
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
                primaryText: String, secondaryText: String? = nil) { ... }
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

    public init(...) { ... }

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
```

### Models/StudyModels.swift
```swift
import Foundation

/// 生词本条目
public struct WordEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var word: String
    public var phonetic: String?
    public var definition: String
    public var translation: String?        // 中文释义
    public var sourceVideoTitle: String?
    public var sourceSentence: String?     // 出现的原句
    public var dateAdded: Date
    public var reviewCount: Int = 0
}

/// 句子收藏
public struct SentenceFavorite: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var primaryText: String
    public var secondaryText: String?
    public var videoTitle: String?
    public var videoTime: TimeInterval?
    public var dateAdded: Date
}

/// 笔记
public struct StudyNote: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var content: String
    public var videoTitle: String?
    public var videoTime: TimeInterval?
    public var sentenceText: String?       // 关联的句子
    public var dateCreated: Date
    public var dateModified: Date
}

/// 词汇分级（Swift 标识符必须为英文，displayName 为中文展示）
public enum VocabularyLevel: String, Codable, CaseIterable, Sendable {
    case cet4 = "四级"
    case cet6 = "六级"
    case kaoyan = "考研"
    case toefl = "托福/雅思"
    case ielts = "GRE"
    case rare = "生僻词"
    case unknown = "未分级"

    public var displayName: String { rawValue }
}

/// 词汇分析结果
public struct VocabularyReport: Identifiable, Codable, Sendable {
    public var id: UUID = UUID()
    public var videoTitle: String?
    public var totalWords: Int              // 去重后词数
    public var levelCounts: [VocabularyLevel: Int]
    public var wordDetails: [WordOccurrence]
}

public struct WordOccurrence: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var word: String
    public var level: VocabularyLevel
    public var count: Int                   // 出现次数
    public var cueIndices: [Int]            // 出现在哪些字幕索引
}

/// 跟读评分记录
public struct ShadowingRecord: Identifiable, Codable, Sendable {
    public var id: UUID = UUID()
    public var sentence: String
    public var score: Int                   // 0-100
    public var audioPath: String?
    public var dateCreated: Date
}
```

### Models/AppSettings.swift
```swift
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
```

### Models/PlaybackModels.swift
```swift
import Foundation

/// 播放列表（队列）
public struct Playlist: Identifiable, Codable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var items: [VideoItem]
    public var currentIndex: Int = 0
}

/// 播放历史记录
public struct PlaybackRecord: Identifiable, Codable, Sendable {
    public var id: UUID = UUID()
    public var videoID: UUID
    public var title: String
    public var position: TimeInterval        // 上次播放位置（秒）
    public var duration: TimeInterval
    public var datePlayed: Date
    public var progress: Double {            // 0...1
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }
}
```

## 4. 服务层协议（**逐字使用**）

### Services/SubtitleParser.swift（agent-subtitle）
```swift
public protocol SubtitleParsing {
    /// 从本地字幕文件解析；自动识别格式（SRT/ASS/VTT/LRC）
    func parse(fileURL: URL) throws -> SubtitleTrack
    /// 从文本内容解析（需显式指定格式）
    func parse(content: String, format: SubtitleFormat) throws -> SubtitleTrack
    /// 双语合并：primary 为主字幕，secondary 为译文字幕，按时间轴对齐（容差 ±0.5s，找不到匹配则留空）
    func mergeBilingual(primary: SubtitleTrack, secondary: SubtitleTrack) -> SubtitleTrack
}

public enum SubtitleParseError: Error, LocalizedError {
    case unsupportedFormat
    case emptyContent
    case malformedLine(String)
    case fileNotReadable(URL)

    public var errorDescription: String? { ... }  // 中文提示
}
```

### Services/SubtitleSynchronizer.swift（agent-subtitle）
```swift
public protocol SubtitleSynchronizing {
    /// 整体平移时间轴
    func offset(_ track: SubtitleTrack, by seconds: TimeInterval) -> SubtitleTrack
    /// 按参考视频的已知锚点线性校准（两个锚点：视频时间→字幕时间）
    func calibrate(_ track: SubtitleTrack, anchors: [(videoTime: TimeInterval, subtitleTime: TimeInterval)]) -> SubtitleTrack
    /// 合并两条字幕为双语（同 mergeBilingual 的转调，放这里一份实现）
    func merge(primary: SubtitleTrack, secondary: SubtitleTrack) -> SubtitleTrack
}
```

### Services/VocabularyAnalyzer.swift（agent-subtitle）
```swift
public protocol VocabularyAnalyzing {
    /// 分析整条字幕轨的词汇，返回分级统计
    func analyze(_ track: SubtitleTrack) -> VocabularyReport
    /// 查询单个单词的等级
    func level(of word: String) -> (level: VocabularyLevel, lemma: String)
    /// 内置词库加载（cet4/cet6/kaoyan/…），从 Bundle 的 txt 读取
    func loadBuiltinDictionaries() throws
}

public enum VocabularyError: Error, LocalizedError {
    case dictionaryNotLoaded
    case analysisFailed(String)
}
```

### Services/DictionaryService.swift（agent-subtitle）
```swift
public protocol DictionaryServiceProtocol {
    /// 本地离线释义（内置精简词典 + 缓存）
    func lookup(_ word: String) -> WordDefinition?
    /// 在线查询（有道/Free Dictionary API，失败降级到本地）
    func lookupOnline(_ word: String) async throws -> WordDefinition
}

public struct WordDefinition: Codable, Sendable {
    public var word: String
    public var phonetic: String?
    public var definitions: [String]        // 英文释义
    public var translation: String?         // 中文释义
    public var examples: [String]
    public var source: String               // "local" / "api"
}
```

### Services/StorageService.swift（agent-skeleton）
```swift
public protocol StorageServiceProtocol {
    /// 读取 JSON 文件到模型；文件不存在时返回 nil
    func load<T: Codable>(_ type: T.Type, from fileName: String) -> T?
    /// 保存模型到 JSON 文件
    func save<T: Codable>(_ object: T, to fileName: String) throws
    /// 删除文件
    func remove(fileName: String) throws
    /// 容器目录（Documents 或 App Group）
    var containerURL: URL { get }
}
```

### Services/HistoryStore.swift（agent-library）
```swift
public protocol HistoryStoring {
    var records: [PlaybackRecord] { get }
    func record(video: VideoItem, position: TimeInterval, duration: TimeInterval)
    func resumePosition(for videoID: UUID) -> TimeInterval?
    func remove(_ record: PlaybackRecord)
    func clearAll()
}
```

### Services/LibraryService.swift（agent-library）
```swift
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
}
```

### Services/NetworkVideoService.swift（agent-library）
```swift
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
```

### Services/ExportService.swift（agent-library）
```swift
public protocol ExportServicing {
    /// 从视频导出音频（AVAssetExportSession → m4a）
    func exportAudio(from video: VideoItem) async throws -> URL
    /// 导出字幕文件（SRT 格式，带时间轴偏移应用）
    func exportSubtitle(_ track: SubtitleTrack, as format: SubtitleFormat) throws -> URL
}
```

## 5. PlayerViewModel 公共 API（agent-player 实现，其他模块只调用不修改）

```swift
@MainActor
public final class PlayerViewModel: ObservableObject {
    // 播放状态
    @Published public private(set) var player: AVPlayer
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var isBuffering: Bool = false
    @Published public private(set) var currentItem: VideoItem?
    @Published public private(set) var rate: Float = 1.0
    @Published public private(set) var volume: Float = 1.0        // 软件音量（非系统）
    @Published public private(set) var isPiPActive: Bool = false
    @Published public private(set) var errorMessage: String?

    // 字幕状态
    @Published public var subtitleTrack: SubtitleTrack?
    @Published public var secondaryTrack: SubtitleTrack?          // 双语第二轨
    @Published public var displayMode: SubtitleDisplayMode = .bilingual
    @Published public var activeCue: SubtitleCue?

    // 循环
    @Published public var loopMode: LoopMode = .off
    @Published public var loopA: TimeInterval?                    // AB 起点
    @Published public var loopB: TimeInterval?                    // AB 终点
    @Published public var sentenceRepeatCount: Int = 0            // 0=无限

    // 控件显隐
    @Published public var controlsVisible: Bool = true
    @Published public var isLocked: Bool = false

    // 播放列表
    public var playlist: [VideoItem] = []
    public var currentIndex: Int = 0

    public init()

    // 加载与播放
    public func load(_ item: VideoItem, playlist: [VideoItem] = [], startAt: TimeInterval? = nil)
    public func play() / pause() / togglePlay()
    public func seek(to time: TimeInterval, precise: Bool = false)
    public func seek(by offset: TimeInterval)                    // 相对跳转（快进快退）
    public func next() / previous()                              // 播放列表上一项/下一项
    public func setRate(_ rate: Float)                           // 0.2...2.5
    public func setVolume(_ v: Float)
    public func stepFrame(forward: Bool)                         // 逐帧（预留）

    // 字幕控制
    public func loadSubtitle(from url: URL)                      // 外挂字幕
    public func loadBilingualSubtitles(primary: URL, secondary: URL)
    public func setDisplayMode(_ mode: SubtitleDisplayMode)
    public func adjustSubtitleOffset(by seconds: TimeInterval)    // 时间轴微调
    public func jumpToCue(_ cue: SubtitleCue)

    // 学习辅助
    public func playPreviousSentence()                            // 上一句
    public func playNextSentence()                                // 下一句
    public func repeatCurrentSentence(count: Int = 0)             // 单句循环
    public func setABLoop(start: TimeInterval?, end: TimeInterval?)
    public func toggleABLoop()

    // 其他
    public func captureScreenshot() -> UIImage?                   // 当前画面截图
    public func enterPiP() / exitPiP()                            // 画中画
    public func toggleLock()
    public func observePeriodicTime()                             // 内部：时间观察+循环逻辑
}
```

**关键实现要求**：
- 循环逻辑放在 `observePeriodicTime()`：单句循环=到达 cue.endTime 回跳 cue.startTime；AB 循环=到 loopB 回跳 loopA。
- 倍速必须支持无级调节（0.2–2.5，步长 0.05）。
- 软件音量用 `player.volume`；同时提供系统 MPVolumeView 的挂载方式（放 PlaylistDrawerView/设置）。
- 截图用 `AVAssetImageGenerator` 或 `AVPlayerItem.videoComposition` + `copyPixelBuffer`（AGXK 上注意异步）。

## 6. UI 设计规范（Web 演示版与 SwiftUI 版保持一致）

- **风格**：深色沉浸式播放器（播放页纯黑背景），媒体库为深灰卡片 + 圆角海报。
- **主色**：鹦鹉黄 `#FFC107` / 强调青 `#26C6DA`；涨跌无关（非金融应用）。
- **播放器布局**（竖屏）：
  - 顶部：返回、标题、投屏、画中画、锁定、更多
  - 中部：字幕显示区（主字幕白色、次字幕黄色，可点击单词）
  - 底部：进度条（缓冲进度+已播放+拖拽圆点）、当前时间/总时长、播放/暂停、上一句/下一句、倍速、字幕设置、AB循环、播放列表
  - 中央手势区：单击=显隐控件；双击左右=快进/退10s；左右滑动=进度（显示进度浮层）；左侧上下滑动=亮度；右侧上下滑动=音量；双指捏合=缩放画面
- **媒体库布局**：顶部"导入/URL/网盘"入口 + 网格海报 + 底部 Tab（媒体库/学习/设置）
- **学习页**：词汇报告卡片、生词本、收藏句子、笔记、跟读练习入口

## 7. 代码规范

- Swift 5.9，SwiftUI，`@MainActor` 隔离 UI 相关 VM。
- 禁止第三方依赖（全部用系统框架），保证 XcodeGen 无 SPM 依赖可直接跑。
- 中文注释 + 中文用户可见文案；代码标识符英文。
- 每个文件顶部加 `// 文件名 + 职责说明`。
- 禁止使用中文作为 Swift 标识符。
- 所有 public 模型字段已由本文档定义，禁止增删改；如需扩展字段，在对应类型里加 `extension` 并在注释说明。

## 8. 并行任务分工

| 任务 | 负责范围 | 输出 |
|---|---|---|
| agent-skeleton | project.yml + App 入口 + RootView + Models/ 全部 + StorageService + Assets | §2 骨架文件 |
| agent-player | ViewModels/PlayerViewModel + Views/Player/* | §5 播放器全部 |
| agent-subtitle | SubtitleParser/Synchronizer/VocabularyAnalyzer/DictionaryService + cet4_words.txt + 字幕渲染组件 SubtitleTextView | §4 字幕学习服务 |
| agent-study | ViewModels/StudyViewModel + Views/Study/* + 跟读 | 学习 UI |
| agent-library | LibraryService/HistoryStore/NetworkVideoService/ExportService + ViewModels/Library+Settings + Views/Library+Settings | 媒体库 |
| agent-web | web-demo/* 完整可运行演示 | Web 演示 |
