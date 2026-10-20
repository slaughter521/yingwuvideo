// 文件: StudyModels.swift — 学习数据模型（生词本、句子收藏、笔记、词汇分级与报告、跟读评分）

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
