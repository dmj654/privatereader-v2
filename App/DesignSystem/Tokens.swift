import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

/// 与 design/视觉设计-v1.html 的色板一一对应，改这里就等于改全站。
enum Palette {
    static let bg = Color(hex: 0xF4F6F8)
    static let surface = Color.white
    static let surfaceAlt = Color(hex: 0xFAFBFC)
    static let line = Color(hex: 0xE7EAEF)
    static let lineStrong = Color(hex: 0xDDE3EA)

    static let ink = Color(hex: 0x141A22)
    static let ink2 = Color(hex: 0x5A6575)
    static let ink3 = Color(hex: 0x8B96A6)

    static let accent = Color(hex: 0x4F7291)
    static let accentDeep = Color(hex: 0x3C5C79)
    static let accentSoft = Color(hex: 0xEAF1F7)

    static let readingDay = Color(hex: 0xF8F9FA)
    static let readingInk = Color(hex: 0x2C323A)
    static let readingNight = Color(hex: 0x0E1116)
    static let readingNightInk = Color(hex: 0xC9D2DC)
    static let comicCanvas = Color(hex: 0xF1F3F6)

    static let danger = Color(hex: 0xB4544A)
}

enum Radius {
    static let control: CGFloat = 10
    static let button: CGFloat = 14
    static let card: CGFloat = 20
    static let sheet: CGFloat = 26
}

enum Spacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 22
    static let xxl: CGFloat = 32
}

enum Typo {
    static let display = Font.system(size: 32, weight: .bold)
    static let title = Font.system(size: 28, weight: .bold)
    static let pageTitle = Font.system(size: 20, weight: .semibold)
    static let headline = Font.system(size: 15.5, weight: .semibold)
    static let body = Font.system(size: 15, weight: .regular)
    static let caption = Font.system(size: 12.5, weight: .regular)
    static let micro = Font.system(size: 11, weight: .regular)
    static let reading = Font.system(size: 17.5, weight: .regular)
}

enum Shadow {
    /// 静止卡片：只压 1px，看不出方向。
    static let card = Color(hex: 0x101828, alpha: 0.04)
    static let cardRadius: CGFloat = 2
    static let cardY: CGFloat = 1
}
