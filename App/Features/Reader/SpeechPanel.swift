import SwiftUI
import AVFoundation

/// 朗读控制面板：双排。
/// 上排管"读哪儿"——翻页、翻章、暂停；下排管"怎么读"——目录、设置、退出、人声、定时。
/// 退出放正中做成主色胶囊：它是这一屏唯一"结束"的动作，值得被单独看见。
struct SpeechPanel: View {
    let isPaused: Bool
    /// 朗读队列已经结束：按钮要能重新开始，而不是显示"播放中"却点不动
    let isStopped: Bool
    let status: String
    let detail: String

    // 跟随阅读主题，避免面板是另一块灰
    let tint: Color
    let ink: Color
    let line: Color

    let onPreviousChapter: () -> Void
    let onPreviousPage: () -> Void
    let onTogglePlay: () -> Void
    let onNextPage: () -> Void
    let onNextChapter: () -> Void

    let onCatalog: () -> Void
    let onSettings: () -> Void
    let onExit: () -> Void
    let onVoice: () -> Void
    let onTimer: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Text(status)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(ink.opacity(0.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)

            HStack(spacing: 0) {
                item("backward.end", "上一章", action: onPreviousChapter)
                item("chevron.left", "上一页", action: onPreviousPage)
                playButton
                item("chevron.right", "下一页", action: onNextPage)
                item("forward.end", "下一章", action: onNextChapter)
            }
            .padding(.horizontal, 8)

            HStack(spacing: 0) {
                item("list.bullet", "目录", action: onCatalog)
                item("slider.horizontal.3", "设置", action: onSettings)

                Button(action: onExit) {
                    Text("退出")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 92, height: 42)
                        .background(Palette.accent)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)

                item("waveform", "人声", action: onVoice)
                item("timer", "定时", action: onTimer)
            }
            .padding(.horizontal, 8)
        }
        .padding(.top, 12)
        .padding(.bottom, 30)
        .glassBottomPanel(tint: tint, tintOpacity: 0.94, line: line)
    }

    private var playButton: some View {
        Button(action: onTogglePlay) {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(Palette.accent)
                        .frame(width: 46, height: 46)
                    Image(systemName: isPaused || isStopped ? "play.fill" : "pause.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }
                Text(isStopped ? "继续听" : (isPaused ? "已暂停" : "播放中"))
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.accent)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func item(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .regular))
                    .frame(height: 22)
                Text(title)
                    .font(.system(size: 10))
            }
            .foregroundStyle(ink.opacity(0.8))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

/// 人声与语速。
///
/// 语速和音色都先放在本地 @State 里：
/// 直接绑到 engine 上会让阅读器整个 body 重算，拖动滑块就像卡住一样。
/// 系统语音列表也只在 onAppear 取一次——枚举语音在 iOS 上并不便宜。
struct VoiceSheet: View {
    @ObservedObject var engine: SpeechEngine
    @Environment(\.dismiss) private var dismiss

    @State private var rate: Float = 0
    @State private var selectedVoiceID: String?
    @State private var voices: [AVSpeechSynthesisVoice] = []

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.bg.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("语速")
                                    .font(.system(size: 13.5))
                                    .foregroundStyle(Palette.ink2)
                                Spacer()
                                Text(rateLabel)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Palette.ink3)
                            }
                            Slider(value: $rate,
                                   in: 0.35...0.65,
                                   step: 0.01,
                                   onEditingChanged: { editing in
                                       // 拖动过程只改本地值；松手才写回引擎，
                                       // 避免每一格都落一次 UserDefaults。
                                       if !editing { engine.rate = rate }
                                   })
                            .tint(Palette.accent)
                        }
                        .padding(14)
                        .background(Palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Palette.line, lineWidth: 1)
                        }

                        Text("音色")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Palette.ink2)

                        if voices.isEmpty {
                            Text("系统里没有中文语音包，请到 设置 → 辅助功能 → 朗读内容 里下载")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Palette.danger)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(voices, id: \.identifier) { voice in
                                    Button {
                                        selectedVoiceID = voice.identifier
                                        engine.voiceIdentifier = voice.identifier
                                    } label: {
                                        HStack(spacing: 10) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(voice.name)
                                                    .font(.system(size: 14))
                                                    .foregroundStyle(Palette.ink)
                                                Text(subtitle(for: voice))
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(Palette.ink3)
                                            }
                                            Spacer(minLength: 0)
                                            if isSelected(voice) {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 13, weight: .semibold))
                                                    .foregroundStyle(Palette.accent)
                                            }
                                        }
                                        .padding(.horizontal, 14)
                                        .frame(height: 52)
                                        .contentShape(Rectangle())
                                        .overlay(alignment: .bottom) {
                                            Rectangle().fill(Color(hex: 0xF3F6F9)).frame(height: 1)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .background(Palette.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Palette.line, lineWidth: 1)
                            }
                        }

                        Text("用的是系统语音，不联网、不上传正文。音质取决于 iOS 自带的中文语音包。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.ink3)
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, Spacing.l)
                }
            }
            .navigationTitle("人声")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onAppear {
            rate = engine.rate
            selectedVoiceID = engine.voiceIdentifier
            // 只取一次：拖动语速时不该反复枚举系统语音
            voices = SpeechEngine.chineseVoices()
        }
    }

    private var rateLabel: String {
        String(format: "%.2f×", Double(rate) / Double(AVSpeechUtteranceDefaultSpeechRate))
    }

    private func isSelected(_ voice: AVSpeechSynthesisVoice) -> Bool {
        if let id = selectedVoiceID { return id == voice.identifier }
        return voice.identifier == SpeechEngine.defaultChineseVoice()?.identifier
    }

    private func subtitle(for voice: AVSpeechSynthesisVoice) -> String {
        var parts = [voice.language]
        switch voice.quality {
        case .premium: parts.append("增强")
        case .enhanced: parts.append("高品质")
        default: break
        }
        return parts.joined(separator: " · ")
    }
}
