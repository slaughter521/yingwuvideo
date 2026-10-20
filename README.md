# 鹦鹉播放器 ParrotPlayer

一款**模仿「小鹦看看」**的 iOS 视频播放器，主打「看视频学外语」：双语字幕、即点即译、无级变速、单句/AB 循环、词汇分析、生词本与影子跟读。

- **平台**：iOS / iPadOS 16.0+（iPhone 与 iPad 通用）
- **技术**：Swift 5.9 + SwiftUI + AVKit/AVFoundation，**零第三方依赖**
- **规模**：42 个 Swift 文件 / 约 10,900 行代码 + 3,356 词内置分级词库

---

## 一、先看效果：Web 高仿演示版

无需 Xcode、无需服务器，**双击打开 `web-demo/index.html`** 即可在浏览器里体验完整 UI 与交互（桌面浏览器中按手机比例呈现）：

- 媒体库：海报墙、继续观看进度卡、导入 URL、拖入本地视频/字幕文件
- 播放页：双语字幕随时间切换、**点击字幕单词弹词卡**、进度条拖拽、倍速面板（0.2–2.5×）、AB 循环与**单句循环**（均真实回跳）、播放列表、投屏/画中画
- 「更多」面板：**截图（含字幕烧录，真实 canvas 抓帧）**、**导出音频 WAV（真实解码编码）**、单句循环 ×3/×5/无限、播放信息
- 手势：双击左右快进快退、横拖调进度、左侧上下调亮度、右侧上下调音量、双指缩放
- 学习页：生词本、收藏句子、笔记、词汇分析报告、跟读练习（含录音与评分动画）
- 设置页：倍速/字幕/学习/手势等开关，全部真实生效并持久化

> 演示版默认加载一个公开示例视频；也支持把本地 `mp4` 与 `srt` 文件直接拖进页面播放（离线亦可演示）。
> 截图与音频导出受浏览器跨域策略限制：远程示例视频会被拦截，**拖入本地视频后这两个功能可完整使用**。

### 自动化验证（39 项，全部通过）

演示版附带三套 jsdom 测试，覆盖真实交互行为而非仅"能否点击"：

```bash
npm install jsdom          # 仅需一次
node web-demo/test-runtime.js    # 15 项：首屏渲染 / 面板 / SRT 解析
node web-demo/test-behavior.js   # 15 项：AB 回跳 / 上下句 / 字幕模式 / 数据流 / 持久化
node web-demo/test-features.js   # 9  项：单句循环回跳 / 截图下载 / WAV 编码校验
```

关键断言示例：AB 循环越过后 `currentTime` 由 10.60 回跳 5.00；单句循环由句尾 1.50 回跳句首 0.00；WAV 输出字节数 = 44 + 采样数×4 且 RIFF/WAVE 头正确。

---

## 二、iOS 工程如何编译运行（需要 Mac + Xcode）

```bash
# 1. 安装 XcodeGen（一次性）
brew install xcodegen

# 2. 生成 Xcode 工程
cd 鹦鹉播放器
xcodegen generate

# 3. 打开并运行
open ParrotPlayer.xcodeproj
```

选择自己的开发者团队（Signing）→ 选择真机或模拟器 → `Cmd + R` 运行。

> 若不装 XcodeGen：在 Xcode 中新建 iOS App（SwiftUI、Swift），然后把 `ParrotPlayer/` 下全部文件拖入工程，勾选 "Copy items if needed"，再把 `Resources/Assets.xcassets` 与 `Resources/Vocabulary` 加入 **Copy Bundle Resources**，`Info.plist` 指定为工程 Info.plist 文件即可。

### 没有 Mac？用 GitHub 云服务器免费验证编译

项目自带 `.github/workflows/build.yml`：把代码传到 GitHub **公开仓库**，云端会自动完成 XcodeGen 生成工程 + xcodebuild 全量编译，并输出错误摘要。零成本验证代码正确性，详见《云端编译验证指南.md》。

### 把视频放进 App 的三种方式

1. **iTunes / 访达文件共享**：连接 Mac，在访达的「文件」标签把视频拖进 App（需开启 UIFileSharingEnabled，已配置）
2. **App 内导入**：媒体库右上角「导入」→ 选择「文件」App 中的视频
3. **远程直链**：右上角「URL」→ 填写 http/https 直链（mp4/mkv/m3u8 等），可选填外挂字幕地址

字幕：把与视频**同名同目录**的 `.srt/.ass/.vtt/.lrc` 一并导入即可自动匹配；也可在播放页「字幕设置 → 导入字幕文件」手动加载。

---

## 三、功能对照「小鹦看看」

| 小鹦看看功能 | 本项目实现情况 |
|---|---|
| 播放几乎所有格式视频 | ✅ AVFoundation 原生解码（mp4/mkv/mov/m4v/avi/flv/wmv/ts/webm…） |
| 点击字幕单词查词（即点即译） | ✅ 字幕分词渲染，点词暂停并弹词卡：音标/释义/例句/朗读/加入生词本 |
| 上一句 / 下一句 | ✅ 按字幕 cue 前后跳转 |
| 无级变速 0.2–2.5x | ✅ Slider 步进 0.05 + 6 个常用预设 |
| 字幕切换（中文/英文/双语/隐藏） | ✅ 四种显示模式，主白次黄 |
| 单句循环 / AB 循环 | ✅ 单句循环可设次数（0=无限）；AB 循环可视化设点、到 B 自动回跳 |
| 查找字幕内容 | ✅ 学习页收藏句子与笔记支持搜索 |
| 字幕词汇分析（四六级/考研词） | ✅ 内置 3,356 词分级词库 + 词形还原 + 停用词过滤，输出分级报告 |
| 列举每个单词出现的句子 | ✅ 词汇报告点词展开全部出现句，可点击跳播 |
| 外挂字幕 + 时间轴调整 | ✅ SRT/ASS/VTT/LRC 解析，±0.1s 微调与两点线性校准 |
| 收藏句子 / 做笔记 | ✅ 收藏句可跳播；笔记增删改查 |
| 提取视频音频并导出 | ✅ AVAssetExportSession 导出 m4a；字幕导出 SRT/VTT |
| 远程地址播放 / 网盘 | ✅ 远程直链探测；阿里云盘/百度网盘已定义接入协议与占位实现 |
| 影子跟读 + 录音评分 | ✅ 录音对比 + 时长吻合度/音量包络余弦相似度评分（0–100） |
| 投屏（AirPlay）/ 画中画 | ✅ AVRoutePickerView 投屏、AVPlayerViewController 画中画 |
| TED / YouTube 资源 | ⚠️ 未内置内容源（需自行接入，接口位已预留） |

### 额外补齐的能力

手势控制（亮度/音量/进度/快进快退/缩放）、断点续播与播放历史、海报墙与网格/列表双视图、收藏与搜索、截图保存相册、字幕位置拖拽、锁屏防误触、深色沉浸主题、设置持久化。

---

## 四、目录结构

```
鹦鹉播放器/
├── ARCHITECTURE.md            # 架构契约：数据模型 / 服务协议 / ViewModel API（开发基准）
├── project.yml                # XcodeGen 配置（xcodegen generate 生成 .xcodeproj）
├── README.md
├── web-demo/                  # 零依赖可运行的高仿演示（index.html + styles.css + app.js）
└── ParrotPlayer/
    ├── ParrotPlayerApp.swift  # @main 入口 + AppSettingsStore
    ├── RootView.swift         # 三 Tab（媒体库/学习/设置）+ ToastCenter + 播放页挂载点
    ├── Models/                # VideoItem / Subtitle* / Study* / AppSettings / Playback*
    ├── Services/              # 字幕解析、时间轴同步、词汇分析、词典、媒体库、历史、网络/网盘、导出、存储
    ├── ViewModels/            # PlayerViewModel / LibraryViewModel / StudyViewModel / SettingsViewModel
    ├── Views/
    │   ├── Player/            # 播放页、控制条、手势层、字幕层、倍速、AB 循环、播放列表
    │   ├── Library/           # 媒体库主页、海报墙、视频行、添加 URL
    │   ├── Study/             # 学习主页、生词本、词卡、收藏、笔记、词汇报告、跟读
    │   ├── Settings/          # 设置页
    │   └── Components/        # 字幕渲染组件（分词点击）
    └── Resources/             # 资源：Assets + 分级词库（cet4/cet6/kaoyan/ielts）
```

### 关键设计

- **播放器**：`AVPlayerViewController` 承载视频（保留 AirPlay/画中画，隐藏系统控件），其上叠加 SwiftUI 字幕层、手势层与控制层；`PlayerViewModel` 用周期时间观察驱动单句循环、AB 循环、句子跳转与历史记录。
- **字幕**：`SubtitleTrack` 支持主/次双语；`SubtitleTextView` 按空格分词渲染，通过 PreferenceKey 收集每个词的屏幕矩形，实现「点哪个词查哪个词」。
- **词汇分析**：内置词库 + 词形还原（复数/过去式/进行时/副词）+ 约 150 个停用词过滤，按 四级→六级→考研→雅思→生僻 优先级分级。
- **持久化**：全部走 JSON（Documents/ParrotPlayerData/），无 Core Data/SwiftData 依赖。
- **模块解耦**：服务层全部协议化（`SubtitleParsing`、`VocabularyAnalyzing`、`DictionaryServiceProtocol`、`LibraryServicing`、`HistoryStoring`、`ExportServicing`、`NetworkVideoServicing`…），便于替换实现。

---

## 五、已知限制

1. **未做真机编译验证**：开发环境为 Windows，无 Xcode。代码按 Swift 5.9 / iOS 16 SDK 规范编写并做了跨模块签名核对，首次在 Xcode 编译时可能仍需微调个别 API（工程已设置 Swift 5 语言模式，并发隔离违规仅为警告）。
2. **网盘为占位实现**：阿里云盘/百度网盘已定义协议与流程注释，真实接入需填入 OAuth 应用信息。
3. **在线词典需联网**：本地内置词典覆盖常用词；查询不到时请求 `dictionaryapi.dev` 补全，失败自动降级。
4. **未内置内容源**：TED/YouTube 资源需自行接入。

---

## 六、典型使用流程

1. 把美剧/演讲视频与同名 `.srt` 字幕一起导入 → 媒体库出现海报
2. 点开播放 → 自动挂载字幕 → 双语字幕显示
3. 遇到生词：**直接点字幕上的单词** → 自动暂停并弹释义 → 「加入生词本」
4. 没听清：点「循环」设单句循环，或把速度拖到 0.6x
5. 想精听某段：AB 循环设 A/B 点，可设重复次数
6. 学完后：学习页查看词汇分析报告（四六级/考研词分布）、复习生词本、做跟读练习
