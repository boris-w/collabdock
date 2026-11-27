import Foundation

/// 可注入时钟协议（供 Core 服务单测确定性控制时间推进、限流退避与节流窗口）
public protocol ClockProviding: Sendable {
    var now: Date { get }
}

/// 生产默认系统时钟
public struct SystemClock: ClockProviding {
    public init() {}

    public var now: Date { Date() }
}
