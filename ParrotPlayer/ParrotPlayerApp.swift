// 文件: ParrotPlayerApp.swift — App 入口（@main）：加载全局设置、注入环境对象、挂载根视图

import SwiftUI

@main
struct ParrotPlayerApp: App {
    /// 全局设置存储（启动时从本地 JSON 加载，缺省使用 AppSettings.default）
    @StateObject private var settingsStore: AppSettingsStore
    /// 全局 Toast 提示中心
    @StateObject private var toastCenter = ToastCenter()

    init() {
        let store = AppSettingsStore()
        _settingsStore = StateObject(wrappedValue: store)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settingsStore)
                .environmentObject(toastCenter)
                .preferredColorScheme(.dark)
        }
    }
}

/// 全局设置存储：加载/保存 AppSettings，以 EnvironmentObject 形式注入视图树
public final class AppSettingsStore: ObservableObject {
    /// 当前设置（修改后调用 save() 持久化）
    @Published public var settings: AppSettings

    private let storage: StorageService
    private let fileName = "settings.json"

    public init(storage: StorageService = StorageService()) {
        self.storage = storage
        // 读取失败或首次启动时回退到默认设置
        self.settings = storage.load(AppSettings.self, from: fileName) ?? .default
    }

    /// 将当前设置写盘（best-effort，失败时静默）
    public func save() {
        try? storage.save(settings, to: fileName)
    }
}
