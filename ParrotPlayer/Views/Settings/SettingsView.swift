// 文件: SettingsView.swift — 设置页：播放/字幕/学习/手势/硬件与存储/关于 分组偏好，改动即时持久化

import Foundation
import SwiftUI
import UIKit

/// 设置页（RootView 的「设置」Tab 直接以 SettingsView() 调用）
/// - 环境注入 AppSettingsStore（字段修改后 save()）
/// - 持有 SettingsViewModel：存储统计、缓存清理、学习数据清空与导出
public struct SettingsView: View {

    @EnvironmentObject private var settingsStore: AppSettingsStore
    @EnvironmentObject private var toastCenter: ToastCenter
    @StateObject private var viewModel: SettingsViewModel

    /// 存储用量文案（异步统计）
    @State private var storageUsageText: String = "计算中…"
    /// 清空学习数据二次确认
    @State private var showingClearConfirm: Bool = false
    /// 学习数据导出（系统分享面板）
    @State private var showingExportSheet: Bool = false
    @State private var exportText: String = ""

    public init() {
        // SettingsViewModel 为 @MainActor 类型，此处先以独立 store 构造，
        // 页面出现（.task）时再绑定环境中的真实 store 与 Toast 回调
        self._viewModel = StateObject(wrappedValue: SettingsViewModel(settingsStore: AppSettingsStore()))
    }

    public var body: some View {
        Form {
            playbackSection
            subtitleSection
            studySection
            gestureSection
            storageSection
            aboutSection
        }
        .scrollContentBackground(.hidden)
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("设置")
        .task {
            await bindViewModel()
            await reloadStorageUsage()
        }
        .alert("清空学习数据", isPresented: $showingClearConfirm) {
            Button("清空", role: .destructive) { viewModel.clearAllData() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将删除播放历史、生词本、收藏句子、笔记与跟读记录，操作不可恢复。")
        }
        .sheet(isPresented: $showingExportSheet) {
            ActivityView(text: exportText)
        }
    }

    // MARK: - 绑定

    /// 将环境注入的 AppSettingsStore 与 Toast 回调交给 ViewModel（主线程执行）
    @MainActor
    private func bindViewModel() {
        viewModel.settingsStore = settingsStore
        viewModel.onToast = { [weak toastCenter] message in
            toastCenter?.show(message)
        }
    }

    // MARK: - 播放

    private var playbackSection: some View {
        Section {
            Stepper(value: defaultSpeedBinding, in: 0.5...2.5, step: 0.05) {
                HStack {
                    Text("默认倍速")
                    Spacer()
                    Text(String(format: "%.2fx", settingsStore.settings.defaultSpeed))
                        .foregroundStyle(.white.opacity(0.6))
                        .monospacedDigit()
                }
            }
            Toggle("记忆倍速", isOn: binding(\.rememberSpeed))
            Toggle("断点续播", isOn: binding(\.resumePlayback))
            Toggle("自动连播", isOn: binding(\.autoPlayNext))
            Toggle("后台音频", isOn: binding(\.backgroundAudio))
        } header: {
            Text("播放")
        }
    }

    /// 默认倍速绑定（经 ViewModel 限制在 0.2...2.5 并持久化）
    private var defaultSpeedBinding: Binding<Float> {
        Binding(
            get: { settingsStore.settings.defaultSpeed },
            set: { viewModel.setDefaultSpeed($0) }
        )
    }

    // MARK: - 字幕

    private var subtitleSection: some View {
        Section {
            Picker("显示模式", selection: binding(\.subtitleDisplayMode)) {
                ForEach(SubtitleDisplayMode.allCases, id: \.self) { mode in
                    Text(Self.title(for: mode)).tag(mode)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("字号")
                    Spacer()
                    Text("\(Int(settingsStore.settings.subtitleFontSize.rounded())) pt")
                        .foregroundStyle(.white.opacity(0.6))
                        .monospacedDigit()
                }
                Slider(value: binding(\.subtitleFontSize), in: 12...28, step: 1)
            }
            ColorPicker("主字幕色", selection: colorBinding(\.subtitlePrimaryColorHex), supportsOpacity: false)
            ColorPicker("次字幕色", selection: colorBinding(\.subtitleSecondaryColorHex), supportsOpacity: false)
            Toggle("字幕背景", isOn: binding(\.showSubtitleBackground))
        } header: {
            Text("字幕")
        }
    }

    // MARK: - 学习

    private var studySection: some View {
        Section {
            Toggle("点词自动暂停", isOn: binding(\.autoPauseOnWordTap))
            Toggle("跟读评分", isOn: binding(\.shadowingScoring))
            Button {
                exportText = viewModel.exportAllStudyData()
                showingExportSheet = true
            } label: {
                Label("导出学习数据", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text("学习")
        }
    }

    // MARK: - 手势

    private var gestureSection: some View {
        Section {
            Toggle("滑动调节亮度", isOn: binding(\.enableBrightnessGesture))
            Toggle("滑动调节音量", isOn: binding(\.enableVolumeGesture))
            Toggle("滑动调节进度", isOn: binding(\.enableSeekGesture))
        } header: {
            Text("手势")
        }
    }

    // MARK: - 硬件与存储

    private var storageSection: some View {
        Section {
            Toggle("硬件解码", isOn: binding(\.hardwareDecoding))
            HStack {
                Text("存储用量")
                Spacer()
                Text(storageUsageText)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Button("清理缓存") { clearCache() }
            Button(role: .destructive) {
                showingClearConfirm = true
            } label: {
                Text("清空学习数据")
            }
        } header: {
            Text("硬件与存储")
        }
    }

    /// 清理缩略图缓存目录并提示
    private func clearCache() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let thumbnails = documents.appendingPathComponent(LibraryService.thumbnailsDirectoryName, isDirectory: true)
        if FileManager.default.fileExists(atPath: thumbnails.path) {
            try? FileManager.default.removeItem(at: thumbnails)
        }
        toastCenter.show("缓存已清理")
        Task { await reloadStorageUsage() }
    }

    /// 异步统计 Documents 占用空间
    @MainActor
    private func reloadStorageUsage() async {
        storageUsageText = await viewModel.storageUsage()
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            HStack {
                Text("版本")
                Spacer()
                Text("鹦鹉播放器 1.0.0 (1)")
                    .foregroundStyle(.white.opacity(0.6))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("简介")
                Text("鹦鹉播放器是一款面向外语学习的本地视频播放器：支持倍速无级调节、双语字幕、点词查词、单句循环与跟读练习，让每一段视频都能当作听力教材。")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("致谢")
                Text("基于 AVFoundation / AVKit 构建")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
            }
        } header: {
            Text("关于")
        }
    }

    // MARK: - 私有辅助

    /// 通用设置字段绑定：写入 AppSettings 后立即持久化
    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settingsStore.settings[keyPath: keyPath] },
            set: { newValue in
                settingsStore.settings[keyPath: keyPath] = newValue
                settingsStore.save()
            }
        )
    }

    /// 字幕色绑定：AppSettings 以 #RRGGBB 字符串存储，UI 使用 Color
    private func colorBinding(_ keyPath: WritableKeyPath<AppSettings, String>) -> Binding<Color> {
        Binding(
            get: { Self.color(fromHex: settingsStore.settings[keyPath: keyPath]) },
            set: { color in
                settingsStore.settings[keyPath: keyPath] = Self.hexString(from: color)
                settingsStore.save()
            }
        )
    }

    /// 字幕显示模式中文名
    private static func title(for mode: SubtitleDisplayMode) -> String {
        switch mode {
        case .bilingual: return "双语"
        case .primaryOnly: return "仅主语言"
        case .secondaryOnly: return "仅译语言"
        case .hidden: return "隐藏"
        }
    }

    /// "#RRGGBB" / "#RRGGBBAA" → Color（解析失败回退白色）
    private static func color(fromHex hex: String) -> Color {
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6 || raw.count == 8 else { return .white }
        var value: UInt64 = 0
        guard Scanner(string: raw).scanHexInt64(&value) else { return .white }
        let divisor: Double = 255
        let r = Double((value >> 16) & 0xFF) / divisor
        let g = Double((value >> 8) & 0xFF) / divisor
        let b = Double(value & 0xFF) / divisor
        if raw.count == 8 {
            let a = Double((value >> 24) & 0xFF) / divisor
            return Color(red: r, green: g, blue: b, opacity: a)
        }
        return Color(red: r, green: g, blue: b)
    }

    /// Color → "#RRGGBB"（动态色/解析失败回退 #FFFFFF）
    private static func hexString(from color: Color) -> String {
        var red: CGFloat = 1
        var green: CGFloat = 1
        var blue: CGFloat = 1
        var alpha: CGFloat = 1
        let uiColor = UIColor(color)
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return "#FFFFFF"
        }
        return String(format: "#%02X%02X%02X",
                      Int(round(red * 255)),
                      Int(round(green * 255)),
                      Int(round(blue * 255)))
    }
}

// MARK: - 系统分享面板

/// 将纯文本（学习数据导出结果）交给系统分享面板
private struct ActivityView: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}
