// 文件: SubtitleTextView.swift — 字幕渲染组件（通用 SwiftUI 组件）
// 职责：播放器中部字幕区复用组件。主字幕按空格分词渲染并支持点词回调
//       （返回单词与命中矩形，供查词浮层定位），支持自动换行（iOS 16 Layout）、
//       双语/仅主/仅次/隐藏四种显示模式与可选暗色半透明圆角底。纯 SwiftUI，无第三方依赖。
import SwiftUI

public struct SubtitleTextView: View {

    // MARK: 公开初始化（签名固定，禁止修改）

    public init(primaryText: String,
                secondaryText: String? = nil,
                mode: SubtitleDisplayMode = .bilingual,
                fontSize: Double = 18,
                onWordTap: ((String, CGRect) -> Void)? = nil) {
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.mode = mode
        self.fontSize = fontSize
        self.onWordTap = onWordTap
    }

    private let primaryText: String
    private let secondaryText: String?
    private let mode: SubtitleDisplayMode
    private let fontSize: Double
    private let onWordTap: ((String, CGRect) -> Void)?

    // MARK: 环境与状态

    /// 是否显示暗色半透明背景（外部可通过 .subtitleBackgroundEnabled(false) 关闭）
    @Environment(\.subtitleBackgroundEnabled) private var backgroundEnabled

    /// 每个分词在屏幕上的矩形（由 PreferenceKey 收集，点词时取命中词）
    @State private var wordRects: [WordRect] = []

    // MARK: 主颜色（与 AppSettings 默认值一致）

    private var primaryColor: Color { Color(red: 1.0, green: 1.0, blue: 1.0) }          // #FFFFFF
    private var secondaryColor: Color { Color(red: 1.0, green: 0.835, blue: 0.310) }    // #FFD54F

    // MARK: 视图主体

    public var body: some View {
        Group {
            if mode == .hidden {
                EmptyView()
            } else {
                content
                    .onPreferenceChange(WordRectPreferenceKey.self) { rects in
                        wordRects = rects
                    }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .hidden:
            // 已在 body 中拦截，双保险返回空视图
            EmptyView()

        case .primaryOnly:
            primaryLine
                .modifier(SubtitleBackgroundModifier(enabled: backgroundEnabled))

        case .secondaryOnly:
            secondaryLine(secondaryText ?? "")
                .modifier(SubtitleBackgroundModifier(enabled: backgroundEnabled))

        case .bilingual:
            VStack(alignment: .leading, spacing: 4) {
                primaryLine
                if let secondary = secondaryText,
                   !secondary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    secondaryLine(secondary)
                }
            }
            .modifier(SubtitleBackgroundModifier(enabled: backgroundEnabled))
        }
    }

    // MARK: 主字幕（分词渲染 + 点词回调）

    private var primaryLine: some View {
        WrappingHStack(spacing: 6) {
            ForEach(words.indices, id: \.self) { index in
                let word = words[index]
                HStack(spacing: 0) {
                    Text(word)
                        .font(.system(size: CGFloat(fontSize)))
                        .foregroundColor(primaryColor)
                        .shadow(color: .black.opacity(0.6), radius: 1.5, x: 0, y: 0.5)
                        .fixedSize()
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: WordRectPreferenceKey.self,
                                    value: [WordRect(word: word, rect: geo.frame(in: .global))]
                                )
                            }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            let rect = wordRects.first { $0.word == word }?.rect ?? .zero
                            onWordTap?(word, rect)
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 次字幕（整段文本，黄色）

    private func secondaryLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: CGFloat(fontSize * 0.85)))
            .foregroundColor(secondaryColor)
            .shadow(color: .black.opacity(0.6), radius: 1.5, x: 0, y: 0.5)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 分词（按空白/换行切分，保留原大小写与标点）

    private var words: [String] {
        primaryText
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            .map(String.init)
    }
}

// MARK: - 暗色背景开关（EnvironmentKey，供外部按需关闭）

struct SubtitleBackgroundEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var subtitleBackgroundEnabled: Bool {
        get { self[SubtitleBackgroundEnabledKey.self] }
        set { self[SubtitleBackgroundEnabledKey.self] = newValue }
    }
}

// MARK: - 暗色半透明圆角背景

private struct SubtitleBackgroundModifier: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.55))
                )
        } else {
            content
        }
    }
}

// MARK: - 分词矩形收集（PreferenceKey）

private struct WordRect: Equatable {
    let word: String
    let rect: CGRect
}

private struct WordRectPreferenceKey: PreferenceKey {
    static var defaultValue: [WordRect] = []

    static func reduce(value: inout [WordRect], nextValue: () -> [WordRect]) {
        value.append(contentsOf: nextValue())
    }
}

// MARK: - 自动换行横排布局（iOS 16+ Layout 协议实现，等价 WrappingHStack）

private struct WrappingHStack: Layout {
    typealias Cache = Void

    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + size.width > maxWidth {
                // 放不下了，换行
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        let width = maxWidth.isFinite ? min(rowWidth - spacing, maxWidth) : rowWidth
        return CGSize(width: max(0, width), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                // 超出右边界，换到下一行
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
