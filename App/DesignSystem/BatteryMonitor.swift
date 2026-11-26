import SwiftUI
import UIKit
import Combine

/// 阅读器底栏的电量显示。
///
/// 为什么要开 `isBatteryMonitoringEnabled`：iOS 默认不报告电量，`batteryLevel` 会一直是 -1。
/// 打开它只影响本 App 的电量采样，代价可以忽略。
final class BatteryMonitor: ObservableObject {
    @Published private(set) var level: Float = -1
    @Published private(set) var isCharging = false

    private var tokens: [NSObjectProtocol] = []

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        update()

        let center = NotificationCenter.default
        for name in [UIDevice.batteryLevelDidChangeNotification,
                     UIDevice.batteryStateDidChangeNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.update()
            })
        }
    }

    deinit {
        let center = NotificationCenter.default
        tokens.forEach { center.removeObserver($0) }
    }

    private func update() {
        let device = UIDevice.current
        level = device.batteryLevel
        isCharging = device.batteryState == .charging || device.batteryState == .full
    }

    var percentText: String {
        guard level >= 0 else { return "—" }
        return "\(Int((level * 100).rounded()))%"
    }

    var symbolName: String {
        if isCharging { return "battery.100.bolt" }
        guard level >= 0 else { return "battery.0" }
        switch level {
        case ..<0.13: return "battery.0"
        case ..<0.38: return "battery.25"
        case ..<0.63: return "battery.50"
        case ..<0.88: return "battery.75"
        default: return "battery.100"
        }
    }

    /// 只在真的低电量、且没在充电时变红；其余时间跟正文同色，不抢注意力。
    var isLow: Bool {
        level >= 0 && level < 0.2 && !isCharging
    }
}
