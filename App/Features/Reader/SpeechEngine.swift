import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// 系统语音朗读的封装。
///
/// 三条约束来自产品前提：
/// 1. 只允许本地系统语音，不联网、不上传正文——所以只用 AVSpeechSynthesizer。
/// 2. 要能锁屏继续播，因此必须配好 audio session 与后台音频模式。
/// 3. 念完一句要能通知外面接着念下一句，所以对外只暴露"一句念完了"这个回调。
final class SpeechEngine: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false

    /// 一句念完（正常结束，不含被打断）
    var onFinishUtterance: (() -> Void)?
    var onRemotePlay: (() -> Void)?
    var onRemotePause: (() -> Void)?
    var onRemoteNext: (() -> Void)?
    var onRemotePrevious: (() -> Void)?

    /// 引擎可以整体换掉：AVSpeechSynthesizer 偶尔会进入"delegate 不再回调、也不出声"的状态，
    /// 此时 stop / speak 都没用，只能丢掉重建。这是"听书卡住只能重启 App"的解法。
    private var synthesizer = AVSpeechSynthesizer()

    /// 存储键。语速与音色是"这个人耳朵的习惯"，必须跨启动记住。
    private enum Key {
        static let rate = "speech.rate"
        static let voice = "speech.voiceIdentifier"
    }

    /// 语速，0.4–0.7 之间比较适合中文。默认比系统默认稍慢一点。
    ///
    /// 刻意**不加 @Published**：滑块每动一格都会发通知，
    /// 阅读器整个 body 会跟着重算（重建当前页富文本），手感就是"调语速会卡"。
    /// 滑块自己维护一份本地值，松手时写回这里。
    var rate: Float = SpeechEngine.storedRate() {
        didSet { UserDefaults.standard.set(rate, forKey: Key.rate) }
    }

    /// 音色同上：不需要让阅读页因为选音色而重绘。
    var voiceIdentifier: String? = UserDefaults.standard.string(forKey: Key.voice) {
        didSet { UserDefaults.standard.set(voiceIdentifier, forKey: Key.voice) }
    }

    /// 当前是否处于"用户希望它读"的状态。
    ///
    /// 这不是 `isSpeaking`：`stopSpeaking` 之后的 `didFinish` 回调可能已经排在主队列上，
    /// 只靠 `isSpeaking` 判断，回调仍会去拿下一章然后重新开口——"退出到书架还在读"就是这么来的。
    private var isPlaybackRequested = false

    /// 用户是否期望继续朗读。阅读页用它判断"该有声却没声"。
    var isActive: Bool { isPlaybackRequested }

    /// 距离上一次"有声音活动"过了多久。翻页看护用它避免把刚念完的短句再念一遍。
    private(set) var lastActivityAt = Date()
    var idleSeconds: TimeInterval { Date().timeIntervalSince(lastActivityAt) }

    // MARK: 卡死看门狗
    //
    // AVSpeechSynthesizer 有两个真实的坏状态：
    // 1. speak 之后 delegate 完全不回调（被别的 App 抢了 audio session、系统音频服务重启）；
    // 2. 念到一半不再出声，也不发 didFinish。
    // 两种状态下 stop/speak 都无效，只能重建实例。没有看门狗就表现为
    // "卡住不动，重启 App 才好"。

    private var currentText: String?
    private var startWatchdog: DispatchWorkItem?
    private var finishWatchdog: DispatchWorkItem?
    private var hasStartedCurrent = false
    private var stallRecoveries = 0
    private var wasInterrupted = false
    /// 被我们主动打断的那一条。它的 didCancel 不该触发"重念"，否则会和新语音打架。
    private var interruptingUtterance: AVSpeechUtterance?

    /// 每条 utterance 开口时的代次。用来识别"迟到的完成通知"：
    /// 用户在这句念完的同一瞬间翻了页，等这条 didFinish 走到主线程时，
    /// 队列已经按新页重建过了——再让它推进一句，就会把新页第一句跳过去，
    /// 或者走到"本章读完"去把整个朗读停掉。
    private var utteranceGenerations: [ObjectIdentifier: Int] = [:]

    // MARK: 静音保活
    //
    // 只用 AVSpeechSynthesizer 时，系统有时不把这段输出当成"媒体播放"，
    // 锁屏就干脆不画正在播放卡片。同时循环播一段静音，让音频会话保持媒体活跃，
    // 卡片才会稳定出现。静音不占音量、不产生可听声音。

    private var silencePlayer: AVAudioPlayer?

    private static let silentWAV: Data = {
        let sampleRate: UInt32 = 8000
        let seconds = 1
        let dataSize = Int(sampleRate) * seconds * 2   // 16-bit mono
        var data = Data()

        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func u32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func u16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }

        ascii("RIFF"); u32(UInt32(36 + dataSize)); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        ascii("data"); u32(UInt32(dataSize))
        data.append(Data(repeating: 0, count: dataSize))
        return data
    }()

    private func startSilentKeeper() {
        if let player = silencePlayer {
            if !player.isPlaying { player.play() }
            return
        }
        guard let player = try? AVAudioPlayer(data: Self.silentWAV) else { return }
        player.numberOfLoops = -1
        player.volume = 0
        player.prepareToPlay()
        player.play()
        silencePlayer = player
    }

    private func stopSilentKeeper() {
        silencePlayer?.stop()
        silencePlayer = nil
    }

    override init() {
        super.init()
        synthesizer.delegate = self
        configureAudioSession()
        configureRemoteCommands()
        observeAudioSession()
    }

    private static func storedRate() -> Float {
        let fallback = AVSpeechUtteranceDefaultSpeechRate * 0.94
        let stored = UserDefaults.standard.float(forKey: Key.rate)
        guard stored > 0 else { return fallback }
        return min(max(stored, 0.3), 0.75)
    }

    // MARK: 播放控制

    /// 每次开口都递增。用来让"被打断的旧请求"失效：
    /// stopSpeaking 是异步的，紧跟着同步 speak 有概率被系统吞掉，
    /// 所以打断后的新语音放到下一个 runloop，并且先核对代次。
    private var speechGeneration = 0
    /// 当前真正在念的那一条。打断后旧 utterance 的回调还会陆续回来，
    /// 不比对的话会把"新的一句"当成念完，白白跳过一句。
    private var currentUtterance: AVSpeechUtterance?

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isPlaybackRequested = true
        currentText = trimmed
        speechGeneration += 1
        let generation = speechGeneration

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = rate
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0.04
        if let identifier = voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            utterance.voice = voice
        } else {
            utterance.voice = Self.defaultChineseVoice()
        }

        let start = { [weak self] in
            guard let self, self.speechGeneration == generation else { return }
            self.activateAudioSession()
            self.startSilentKeeper()
            self.currentUtterance = utterance
            self.utteranceGenerations[ObjectIdentifier(utterance)] = generation
            self.synthesizer.speak(utterance)
            self.isSpeaking = true
            self.isPaused = false
            self.lastActivityAt = Date()
            self.updateNowPlaying()
        }

        armWatchdogs(for: trimmed, generation: generation)

        if (synthesizer.isSpeaking || synthesizer.isPaused), currentUtterance != nil {
            // 真的有另一条在念：主动打断
            interruptingUtterance = currentUtterance
            synthesizer.stopSpeaking(at: .immediate)
            DispatchQueue.main.async(execute: start)
        } else if synthesizer.isSpeaking {
            // 刚 didFinish、引擎内部还没收尾。此时 stop 会让它进入不回调的状态，
            // 表现就是"句末接下一句时卡住"。放到下一个 runloop 直接开口。
            DispatchQueue.main.async(execute: start)
        } else {
            start()
        }
    }

    // MARK: 卡死恢复

    private func armWatchdogs(for text: String, generation: Int) {
        startWatchdog?.cancel()
        hasStartedCurrent = false

        // 启动看门狗：3 秒还不开口，就是引擎坏了
        let startItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.speechGeneration == generation,
                  self.isPlaybackRequested,
                  !self.hasStartedCurrent else { return }
            self.recoverFromStall()
        }
        startWatchdog = startItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: startItem)

        armFinishWatchdog(for: text, generation: generation)
    }

    /// 只负责"念太久还没念完"。暂停恢复时也用它重新计时。
    private func armFinishWatchdog(for text: String, generation: Int) {
        finishWatchdog?.cancel()

        // 中文按每秒 4 字估，留 1.8 倍余量
        let expected = min(max(Double(text.count) / 4.0, 5), 90)
        let finishItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.speechGeneration == generation,
                  self.isPlaybackRequested,
                  self.isSpeaking,
                  !self.isPaused else { return }
            self.recoverFromStall()
        }
        finishWatchdog = finishItem
        DispatchQueue.main.asyncAfter(deadline: .now() + expected * 1.4 + 6, execute: finishItem)
    }

    /// 进度心跳：合成器每准备念一段文字就会回调一次 willSpeakRange。
    /// 只要还在推进，就把看门狗往后推；8 秒没有新进度，就是真的卡住了。
    ///
    /// 之前只用"按字数估算总时长"来兜底，一句 2 个字的短句要等十几秒才判定卡死，
    /// 用户体感就是"读到这儿就不动了"。
    private func armProgressWatchdog() {
        finishWatchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isPlaybackRequested,
                  self.isSpeaking,
                  !self.isPaused else { return }
            self.recoverFromStall()
        }
        finishWatchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: item)
    }

    private func recoverFromStall() {
        guard isPlaybackRequested else { return }
        stallRecoveries += 1

        let text = currentText
        rebuildSynthesizer()
        isSpeaking = false
        isPaused = false

        guard stallRecoveries <= 3, let text else {
            // 重建三次仍不行就停手，别无限重试把电耗光
            isPlaybackRequested = false
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }
        speak(text)
    }

    private func rebuildSynthesizer() {
        startWatchdog?.cancel()
        finishWatchdog?.cancel()
        interruptingUtterance = nil
        currentUtterance = nil
        utteranceGenerations.removeAll()
        stopSilentKeeper()
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.delegate = nil
        synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
    }

    // MARK: 音频中断

    private func observeAudioSession() {
        isSessionActive = false
        let center = NotificationCenter.default
        center.addObserver(self,
                           selector: #selector(handleInterruption(_:)),
                           name: AVAudioSession.interruptionNotification,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(handleMediaServicesReset),
                           name: AVAudioSession.mediaServicesWereResetNotification,
                           object: nil)
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            // 系统已接管音频；这里只做标记，主动 stop 反而更难恢复
            wasInterrupted = true
            isSessionActive = false
        case .ended:
            guard wasInterrupted else { return }
            wasInterrupted = false
            guard isPlaybackRequested else { return }

            activateAudioSession()
            startSilentKeeper()
            if !synthesizer.isSpeaking, let text = currentText {
                // 被来电等打断后合成器已经没了当前这句，重念它
                speak(text)
            } else if isPaused {
                synthesizer.continueSpeaking()
            }
        @unknown default:
            break
        }
    }

    @objc private func handleMediaServicesReset() {
        guard isPlaybackRequested else { return }
        rebuildSynthesizer()
        if let text = currentText { speak(text) }
    }

    func pause() {
        guard synthesizer.isSpeaking, !synthesizer.isPaused else { return }
        synthesizer.pauseSpeaking(at: .word)
        isPaused = true
        // 暂停期间没有 didFinish，看门狗必须停掉，否则会被当成"卡死"重念
        startWatchdog?.cancel()
        finishWatchdog?.cancel()
        updateNowPlaying()
    }

    func resume() {
        guard synthesizer.isPaused else { return }
        synthesizer.continueSpeaking()
        isPaused = false
        // 恢复后重新计一次（按整句估算，只会多给时间，不会误判）
        if let text = currentText {
            armFinishWatchdog(for: text, generation: speechGeneration)
        }
        updateNowPlaying()
    }

    func stop() {
        // 先关掉"应该继续读"的开关，再停声音。顺序反了的话，
        // 排队中的 didFinish 会看到开关还开着，接着去念下一章。
        isPlaybackRequested = false
        // 让已经排队、但还没执行的新语音请求作废。
        speechGeneration += 1
        startWatchdog?.cancel()
        finishWatchdog?.cancel()
        startWatchdog = nil
        finishWatchdog = nil
        hasStartedCurrent = false
        stallRecoveries = 0
        currentText = nil
        interruptingUtterance = nil
        currentUtterance = nil
        utteranceGenerations.removeAll()
        stopSilentKeeper()
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        isPaused = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    // MARK: 音色

    static func chineseVoices() -> [AVSpeechSynthesisVoice] {
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh") }
        // 质量高的排前面：premium > enhanced > default
        return voices.sorted { lhs, rhs in
            if lhs.quality.rawValue != rhs.quality.rawValue {
                return lhs.quality.rawValue > rhs.quality.rawValue
            }
            return lhs.name < rhs.name
        }
    }

    /// 缓存一次。`speechVoices()` 在 iOS 上要枚举系统语音，每句都调会拖慢开口。
    private static let cachedDefaultVoice: AVSpeechSynthesisVoice? = {
        let voices = chineseVoices()
        return voices.first { $0.language == "zh-CN" } ?? voices.first
    }()

    static func defaultChineseVoice() -> AVSpeechSynthesisVoice? {
        cachedDefaultVoice
    }

    // MARK: 音频会话与锁屏

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        // 不带 duckOthers：听书时应该独占播放，也让系统更明确地把它当成媒体播放。
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        // 锁屏 / 控制中心的「正在播放」卡片要能收到远程控制事件，必须显式开始接收。
        UIApplication.shared.beginReceivingRemoteControlEvents()
    }

    private var isSessionActive = false

    private func activateAudioSession() {
        guard !isSessionActive else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            isSessionActive = true
        } catch {
            // 激活失败通常是被别的 App 占着；下一次 speak 还会再试
        }
    }

    /// 锁屏与控制中心上的信息。
    ///
    /// 用最小字段集：title / artist / album / 播放速率。
    /// 之前塞了 IsLiveStream 和 MediaType，反而可能让系统判断成"非媒体"，锁屏不画卡片。
    /// iOS 16 还要求 playbackState，否则系统不认这个 App 正在播。
    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()

        guard isSpeaking else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlayingTitle,
            MPMediaItemPropertyArtist: nowPlayingSubtitle,
            MPMediaItemPropertyAlbumTitle: "私阅读",
            MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0.0 : 1.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if let artwork = nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        center.nowPlayingInfo = info
        center.playbackState = isPaused ? .paused : .playing
    }

    private var nowPlayingTitle: String = "私阅读"
    private var nowPlayingSubtitle: String = "朗读中"
    var nowPlayingArtwork: MPMediaItemArtwork?

    func updateMetadata(title: String, subtitle: String) {
        nowPlayingTitle = title
        nowPlayingSubtitle = subtitle
        updateNowPlaying()
    }

    /// 切后台 / 锁屏前再刷一次。有的系统版本会在 App 进入后台时丢掉 Now Playing 信息，
    /// 出一次声音就让系统重新认领这张卡片。
    func refreshNowPlaying() {
        updateNowPlaying()
    }

    /// 锁屏封面。没有封面时锁屏只有一行书名，有封面才像"正在播放"。
    func setArtwork(_ image: UIImage?) {
        if let image {
            nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        } else {
            nowPlayingArtwork = nil
        }
        updateNowPlaying()
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true

        center.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.onRemotePlay?() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.onRemotePause?() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.isPaused { self.onRemotePlay?() } else { self.onRemotePause?() }
            }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.onRemoteNext?() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.onRemotePrevious?() }
            return .success
        }
    }
}

extension SpeechEngine: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            guard utterance === self.currentUtterance else { return }
            self.startWatchdog?.cancel()
            self.hasStartedCurrent = true
            self.stallRecoveries = 0
            self.isSpeaking = true
            self.lastActivityAt = Date()
            self.isPaused = false
            self.armProgressWatchdog()
            self.updateNowPlaying()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            guard utterance === self.currentUtterance else { return }
            // 有进度就说明没卡，把看门狗往后推
            self.hasStartedCurrent = true
            self.stallRecoveries = 0
            self.lastActivityAt = Date()
            self.armProgressWatchdog()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            // 旧 utterance 的完成通知晚到了：它既不该改状态，也不该推进队列，
            // 否则会把用户刚翻到的那一页的第一句直接跳过去。
            guard utterance === self.currentUtterance else { return }
            self.startWatchdog?.cancel()
            self.finishWatchdog?.cancel()
            self.isSpeaking = false
            self.currentUtterance = nil
            self.lastActivityAt = Date()

            // 这条通知是否还属于最新的一次开口？用户翻页/跳章会触发新的 speak，
            // 代次已经变了，旧回调不能再推进队列。
            let generation = self.utteranceGenerations.removeValue(forKey: ObjectIdentifier(utterance))
            guard generation == self.speechGeneration else { return }

            // 已经 stop 过就不要再接下一句。退出阅读器时最怕这个：
            // 用户已经回到书架，声音却从下一章重新冒出来。
            guard self.isPlaybackRequested else { return }
            self.onFinishUtterance?()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            let generation = self.utteranceGenerations.removeValue(
                forKey: ObjectIdentifier(utterance)
            )
            // 连续点「下一句」时，前一条的取消通知会晚到。
            // 它既不能改当前状态，也不能触发重念，否则会和最新一句打架——
            // 表现就是连点几次之后声音断掉或卡住。
            guard generation == self.speechGeneration else { return }

            // 我们主动打断换句：这条 cancel 是预期的，不要重念
            if utterance === self.interruptingUtterance {
                self.interruptingUtterance = nil
                return
            }
            guard utterance === self.currentUtterance else { return }
            self.isSpeaking = false
            self.isPaused = false
            self.lastActivityAt = Date()
            self.startWatchdog?.cancel()
            self.finishWatchdog?.cancel()

            // 系统自己取消了这句（音频服务异常、被别的 App 抢走），
            // 不发 didFinish 也不出声，队列会永远停在这里——只能重念当前句。
            guard self.isPlaybackRequested, !self.wasInterrupted, !self.isPaused else { return }
            guard let text = self.currentText else { return }
            self.speak(text)
        }
    }
}
