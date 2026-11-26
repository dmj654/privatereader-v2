import SwiftUI

enum ReaderTheme: String, CaseIterable, Identifiable, Codable {
    case day, eyeCare, night, black

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return "日间"
        case .eyeCare: return "护眼"
        case .night: return "夜间"
        case .black: return "纯黑"
        }
    }

    var background: Color {
        switch self {
        case .day: return Color(hex: 0xF8F9FA)
        case .eyeCare: return Color(hex: 0xEDEFE7)
        case .night: return Color(hex: 0x0E1116)
        case .black: return .black
        }
    }

    var textColor: Color {
        switch self {
        case .day, .eyeCare: return Color(hex: 0x2C323A)
        case .night, .black: return Color(hex: 0xC9D2DC)
        }
    }

    var chromeStyle: ColorScheme { self == .night || self == .black ? .dark : .light }

    /// 阅读器里的浮层/按钮底色。必须是实色：以前用 6% 文字色，
    /// 底下的正文会透出来，看起来像脏了一块。
    var chromeSurface: Color {
        switch self {
        case .day: return Color(hex: 0xFFFFFF)
        case .eyeCare: return Color(hex: 0xF6F7F0)
        case .night: return Color(hex: 0x1A1F26)
        case .black: return Color(hex: 0x14171B)
        }
    }

    var isDark: Bool { self == .night || self == .black }
}
