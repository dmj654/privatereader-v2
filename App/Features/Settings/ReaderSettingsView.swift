import SwiftUI
import AVFoundation
import ReaderCore

/// 设置页里的「阅读设置」：改的是全局默认值，阅读器里的调整也会同步到这里。
struct ReaderSettingsView: View {
    @StateObject private var prefs = ReaderPreferences()

    @State private var rate: Double = Double(UserDefaults.standard.object(forKey: "speech.rate") as? Float
                                             ?? AVSpeechUtteranceDefaultSpeechRate)
    @State private var voiceIdentifier: String? = UserDefaults.standard.string(forKey: "speech.voiceIdentifier")
    @State private var voices: [AVSpeechSynthesisVoice] = []

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    typographyCard
                    themeCard
                    speechCard
                    Text("这些是默认值。在阅读器里调字号、行距、主题也会写回这里。")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.ink3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, 14)
            }
        }
        .navigationTitle("阅读设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if voices.isEmpty { voices = SpeechEngine.chineseVoices() }
        }
    }

    private var typographyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                sliderRow("字号",
                          value: "\(Int(prefs.style.fontSize))",
                          binding: Binding(
                            get: { prefs.style.fontSize },
                            set: { prefs.style.fontSize = $0 }
                          ),
                          range: 14...24, step: 0.5)

                divider

                sliderRow("行距",
                          value: String(format: "%.2f×", prefs.style.lineHeightMultiple),
                          binding: Binding(
                            get: { prefs.style.lineHeightMultiple },
                            set: { prefs.style.lineHeightMultiple = $0 }
                          ),
                          range: 1.4...2.6, step: 0.05)

                divider

                Toggle(isOn: Binding(
                    get: { prefs.style.indentFirstLine },
                    set: { prefs.style.indentFirstLine = $0 }
                )) {
                    Text("段首缩进两字")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Palette.ink)
                }
                .tint(Palette.accent)
            }
        }
    }

    private var themeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("阅读主题")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.ink2)

                HStack(spacing: 10) {
                    ForEach(ReaderTheme.allCases, id: \.rawValue) { theme in
                        Button {
                            prefs.theme = theme
                        } label: {
                            VStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(theme.background)
                                    .frame(height: 40)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(
                                                prefs.theme == theme ? Palette.accent : Palette.line,
                                                lineWidth: prefs.theme == theme ? 1.8 : 1
                                            )
                                    }
                                Text(theme.title)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(prefs.theme == theme ? Palette.ink : Palette.ink3)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var speechCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                sliderRow("语速",
                          value: String(format: "%.2f×", rate / Double(AVSpeechUtteranceDefaultSpeechRate)),
                          binding: Binding(
                            get: { rate },
                            set: { newValue in
                                rate = newValue
                                UserDefaults.standard.set(Float(newValue), forKey: "speech.rate")
                            }
                          ),
                          range: 0.35...0.65, step: 0.01)

                divider

                Menu {
                    Button("系统默认") {
                        voiceIdentifier = nil
                        UserDefaults.standard.removeObject(forKey: "speech.voiceIdentifier")
                    }
                    ForEach(voices, id: \.identifier) { voice in
                        Button(voice.name) {
                            voiceIdentifier = voice.identifier
                            UserDefaults.standard.set(voice.identifier, forKey: "speech.voiceIdentifier")
                        }
                    }
                } label: {
                    HStack {
                        Text("音色")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.ink2)
                        Spacer()
                        Text(currentVoiceName)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.ink3)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.ink3)
                    }
                    .frame(height: 34)
                }
            }
        }
    }

    private var currentVoiceName: String {
        guard let voiceIdentifier,
              let voice = voices.first(where: { $0.identifier == voiceIdentifier }) else {
            return "系统默认"
        }
        return voice.name
    }

    private var divider: some View {
        Rectangle().fill(Palette.line).frame(height: 0.5)
    }

    private func sliderRow(_ title: String,
                           value: String,
                           binding: Binding<Double>,
                           range: ClosedRange<Double>,
                           step: Double) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink2)
                Spacer()
                Text(value)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Palette.ink3)
            }
            Slider(value: binding, in: range, step: step)
                .tint(Palette.accent)
        }
    }
}
