import Foundation

/// 全书进度换算：章序号 + 章内比例 → 0…1。
public enum ProgressMath {
    public static func percent(chapterIndex: Int, chapterCount: Int, chapterProgress: Double) -> Double {
        guard chapterCount > 0 else { return 0 }
        let index = max(0, min(chapterIndex, chapterCount - 1))
        let within = max(0, min(chapterProgress, 1))
        let value = (Double(index) + within) / Double(chapterCount)
        return max(0, min(value, 1))
    }

    /// 用进度反推章节，用于「接着读」。
    public static func chapterIndex(fromPercent percent: Double, chapterCount: Int) -> Int {
        guard chapterCount > 0 else { return 0 }
        let index = Int(floor(max(0, min(percent, 1)) * Double(chapterCount)))
        return max(0, min(index, chapterCount - 1))
    }
}
