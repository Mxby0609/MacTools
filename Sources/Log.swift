import Foundation
import os

/// 每个功能一个类别，可以用 `log show --predicate 'category == "窗口居中"'` 单独筛选。
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier!
    static let lidAwake = Logger(subsystem: subsystem, category: "合盖运行")
    static let windowCentering = Logger(subsystem: subsystem, category: "窗口居中")
}
