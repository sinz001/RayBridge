import AVFoundation
import Speech

struct SpeechVoiceOption: Identifiable, Hashable {
    let id: String
    let name: String
    let language: String
    let languageName: String
    let qualityName: String

    var isKorean: Bool { language == "ko-KR" }
    var previewText: String {
        isKorean ? "안녕하세요. 레이브리지입니다. 선택한 목소리로 답변을 읽어 드릴게요."
            : "Hello. I’m the RayBridge voice. I’ll read answers to you."
    }

    var displayName: String { "\(name), \(qualityName), \(languageName)" }
}

@MainActor
final class SpeechController: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    var onVoiceCommand: ((VoiceCommand) -> Void)?
    var voiceCommandsEnabled = true
    var questionCommands: Set<VoiceCommand> = [.stop, .cancel, .mute, .status, .repeat, .commands]
    private var commandRestart: Task<Void, Never>?
    private var commandFailures = 0
    var onQuestion: ((String) -> Void)?
    var onTranscript: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onFinishedSpeaking: (() -> Void)?
    var onStartedListening: (() -> Void)?
    private let engine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private let confirmationSynthesizer = AVSpeechSynthesizer()
    private var recognition: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var silence: Task<Void, Never>?
    private var limit: Task<Void, Never>?
    private var tapped = false
    private var listening = false
    private var generation = 0
    private var transcript = ""
    private var noticeUtterance: AVSpeechUtterance?
    private var spokenUtterance: AVSpeechUtterance?
    private var confirmationUtterances: [AVSpeechUtterance] = []
    private var confirmationCompletion: (() -> Void)?
    private var resumeHeartbeatAfterConfirmation = false
    private var answerPlayer: AVAudioPlayer?
    // Sentences of an answer that is still being written. Listening resumes only
    // once the last queued sentence has been spoken and the answer is complete.
    private var streamedUtterances: [AVSpeechUtterance] = []
    private var streamedAnswerComplete = true
    private enum CueAction { case startListening, submit(String) }
    private var cuePlayer: AVAudioPlayer?
    private var cueAction: CueAction?
    private var heartbeatPlayer: AVAudioPlayer?
    var allowPhoneAudio = false
    var voiceIdentifier: String?
    var announcementVoiceIdentifier: String?
    var hasAnswerOutput: Bool {
        let readingAnswer = spokenUtterance != nil && spokenUtterance !== noticeUtterance
        return readingAnswer || !streamedUtterances.isEmpty || !streamedAnswerComplete || answerPlayer != nil
    }
    var isSpeaking: Bool {
        synthesizer.isSpeaking || answerPlayer?.isPlaying == true || confirmationSynthesizer.isSpeaking
    }

    override init() {
        super.init()
        synthesizer.delegate = self
        confirmationSynthesizer.delegate = self
    }

    func availableVoiceOptions() -> [SpeechVoiceOption] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "ko-KR" || $0.language.hasPrefix("en-") }
            .sorted { left, right in
                let leftLanguage = Self.languageRank(left.language)
                let rightLanguage = Self.languageRank(right.language)
                if leftLanguage != rightLanguage { return leftLanguage > rightLanguage }
                let leftQuality = Self.qualityRank(left.quality)
                let rightQuality = Self.qualityRank(right.quality)
                if leftQuality != rightQuality { return leftQuality > rightQuality }
                if left.name != right.name { return left.name.localizedStandardCompare(right.name) == .orderedAscending }
                return left.identifier < right.identifier
            }
            .map { voice in
                SpeechVoiceOption(
                    id: voice.identifier,
                    name: voice.name,
                    language: voice.language,
                    languageName: Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language,
                    qualityName: Self.qualityName(voice.quality)
                )
            }
    }

    private var selectedVoice: AVSpeechSynthesisVoice? {
        voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
            ?? AVSpeechSynthesisVoice(language: "ko-KR")
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    private static func languageRank(_ language: String) -> Int {
        switch language {
        case "ko-KR": return 2
        case "en-US": return 1
        default: return 0
        }
    }

    private static func qualityRank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: return 2
        case .enhanced: return 1
        default: return 0
        }
    }

    private static func qualityName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Standard"
        }
    }

    func permissions() async throws {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        try Task.checkCancellation()
        guard speech == .authorized else { throw BridgeError.message("Allow speech recognition in iPhone Settings for RayBridge.") }
        guard await AVAudioApplication.requestRecordPermission() else {
            throw BridgeError.message("Allow microphone access in iPhone Settings for RayBridge.")
        }
        try Task.checkCancellation()
    }
    private func audioSession() throws {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
        if allowPhoneAudio { options.insert(.defaultToSpeaker) }
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        } catch {
            RayBridgeDiagnostics.event("Audio startup failed while setting the audio session category")
            throw error
        }
        do {
            try session.setActive(true)
        } catch {
            RayBridgeDiagnostics.event("Audio startup failed while activating the audio session")
            throw error
        }
        if let glasses = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
            do {
                try session.setPreferredInput(glasses)
            } catch {
                RayBridgeDiagnostics.event("Audio startup failed while selecting the glasses microphone")
                throw error
            }
        } else if !allowPhoneAudio {
            throw BridgeError.message("Connect your glasses as a Bluetooth headset before listening.")
        } else {
            do {
                try session.setPreferredInput(nil)
            } catch {
                RayBridgeDiagnostics.event("Audio startup failed while selecting the iPhone microphone")
                throw error
            }
        }
    }
    var hasBluetoothRoute: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .bluetoothHFP || $0.portType == .bluetoothA2DP }
    }
    var hasRecognitionPermissions: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized &&
            AVAudioApplication.shared.recordPermission == .granted
    }
    func startListening() throws {
        cancelCue()
        try startRecognition(commands: [])
    }
    func startListeningRecoveringAudio() async throws {
        do {
            try startListening()
        } catch {
            guard (error as NSError).code == -50 else { throw error }
            RayBridgeDiagnostics.event("Audio startup returned -50; resetting and retrying")
            resetAudioForRetry()
            try await Task.sleep(for: .milliseconds(200))
            do {
                try startListening()
                RayBridgeDiagnostics.event("Audio startup retry succeeded")
            } catch {
                RayBridgeDiagnostics.event("Audio startup retry failed")
                throw error
            }
        }
    }
    func startCommandListening(for commands: Set<VoiceCommand>) throws {
        guard voiceCommandsEnabled, !commands.isEmpty else { return }
        commandFailures = 0
        try startRecognition(commands: commands)
    }
    private func questionRecognizer() throws -> SFSpeechRecognizer {
        let korean = Locale(identifier: "ko-KR").identifier(.bcp47)
        guard let locale = SFSpeechRecognizer.supportedLocales().first(where: { $0.identifier(.bcp47) == korean }),
              let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.locale.identifier(.bcp47) == korean else {
            throw BridgeError.message("이 iPhone에서는 한국어 음성 인식을 지원하지 않습니다.")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw BridgeError.message("이 iPhone에서 한국어 온디바이스 음성 인식을 사용할 수 없습니다.")
        }
        guard recognizer.isAvailable else {
            throw BridgeError.message("지금은 한국어 음성 인식을 사용할 수 없습니다. 잠시 후 다시 시도해 주세요.")
        }
        return recognizer
    }

    private func startRecognition(commands: Set<VoiceCommand>) throws {
        stopListening()
        let recognizer: SFSpeechRecognizer
        if commands.isEmpty {
            recognizer = try questionRecognizer()
        } else {
            // Command-only sessions listen for the existing English command vocabulary.
            guard let english = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
                  english.isAvailable, english.supportsOnDeviceRecognition else {
                throw BridgeError.message("On-device English speech recognition is unavailable. Enable it on this iPhone, or type your question below.")
            }
            recognizer = english
        }
        try audioSession()
        // Voice processing reduces playback leaking into the microphone. Keep
        // other audio ducking minimal so the answer remains audible.
        let input = engine.inputNode
        if input.isVoiceProcessingEnabled != voiceCommandsEnabled {
            do {
                try input.setVoiceProcessingEnabled(voiceCommandsEnabled)
            } catch {
                RayBridgeDiagnostics.event("Audio startup failed while configuring voice processing")
                throw error
            }
        }
        if voiceCommandsEnabled {
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                enableAdvancedDucking: false, duckingLevel: .min)
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = commands.isEmpty ? .dictation : .confirmation
        if !commands.isEmpty { request.contextualStrings = commands.map(\.rawValue).sorted() }
        self.request = request
        transcript = ""; listening = true
        generation += 1
        let current = generation
        let recognitionStarted = ContinuousClock.now
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { stopListening(); throw BridgeError.message("The microphone is not available.") }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        tapped = true
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            let failure = error?.localizedDescription
            Task { @MainActor in
                guard let self, self.listening, current == self.generation else { return }
                if !commands.isEmpty {
                    if let text, !text.isEmpty {
                        let changed = text != self.transcript
                        self.transcript = text
                        if final {
                            self.submitCommandTranscript(commands: commands)
                            return
                        }
                        if changed {
                            // Wait briefly for another word so “stop reading” is
                            // not mistaken for the standalone Stop command.
                            self.silence?.cancel()
                            self.silence = Task { [weak self] in
                                try? await Task.sleep(for: .milliseconds(650))
                                guard !Task.isCancelled else { return }
                                self?.submitCommandTranscript(commands: commands)
                            }
                        }
                    }
                    if failure != nil {
                        // Silence may end a healthy recognition task. Only rapid,
                        // repeated failures count toward the recovery limit.
                        self.restartCommandRecognition(
                            failed: !final && recognitionStarted.duration(to: .now) < .seconds(2),
                            commands: commands)
                    }
                    return
                }
                if let text, !text.isEmpty {
                    let changed = text != self.transcript
                    self.transcript = text; self.onTranscript?(text)
                    if final { self.submit(); return }
                    if changed {
                        self.silence?.cancel()
                        self.silence = Task { [weak self] in
                            try? await Task.sleep(for: .milliseconds(1400))
                            guard !Task.isCancelled else { return }
                            self?.submit()
                        }
                    }
                }
                if failure != nil {
                    self.stopListening()
                    self.onError?("한국어 음성 인식이 중단되었습니다. Start RayBridge를 눌러 다시 시도해 주세요.")
                }
            }
        }
        do { engine.prepare(); try engine.start() }
        catch {
            RayBridgeDiagnostics.event("Audio startup failed while starting the audio engine")
            stopListening()
            throw error
        }
        limit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled, let self else { return }
            if !commands.isEmpty {
                self.restartCommandRecognition(failed: false, commands: commands)
            } else if !self.transcript.isEmpty { self.submit() }
            else {
                do { try self.startListening() } catch { self.onError?(error.localizedDescription) }
            }
        }
    }
    private func submitCommandTranscript(commands: Set<VoiceCommand>) {
        guard listening else { return }
        let command = VoiceCommandPolicy.command(in: transcript)
        stopListening()
        if let command, commands.contains(command) {
            onVoiceCommand?(command)
        } else {
            restartCommandRecognition(failed: false, commands: commands)
        }
    }
    private func restartCommandRecognition(failed: Bool, commands: Set<VoiceCommand>) {
        commandFailures = failed ? commandFailures + 1 : 0
        stopListening()
        guard commandFailures <= 3 else {
            onError?("Voice command listening stopped working. Start RayBridge again, or turn off voice commands in Setup.")
            return
        }
        commandRestart = Task { [weak self] in
            if failed { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled, let self else { return }
            do { try self.startRecognition(commands: commands) }
            catch { self.onError?(error.localizedDescription) }
        }
    }
    private func submit() {
        guard listening, !transcript.isEmpty else { return }
        let text = transcript
        stopListening()
        if voiceCommandsEnabled, let command = VoiceCommandPolicy.command(in: text), questionCommands.contains(command) {
            onVoiceCommand?(command)
            return
        }
        do {
            try playCue(Self.stoppedListeningCue, action: .submit(text))
        } catch {
            // The question should still be submitted if the optional cue cannot play.
            onQuestion?(text)
        }
    }
    func stopListening() {
        listening = false; generation += 1
        silence?.cancel(); limit?.cancel(); commandRestart?.cancel(); commandRestart = nil
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        request?.endAudio(); recognition?.cancel(); recognition = nil; request = nil
    }
    private func resetAudioForRetry() {
        stopListening()
        engine.reset()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    func startListeningWithCue() throws {
        stopThinkingHeartbeat()
        cancelCue()
        stopListening()
        try playCue(Self.listeningCue, action: .startListening)
    }
    func speakCommandConfirmation(
        _ text: String,
        preservingCurrentOutput: Bool,
        completion: @escaping () -> Void
    ) throws {
        try speakCommandConfirmation(
            [text],
            pauseBetweenPhrases: 0,
            preservingCurrentOutput: preservingCurrentOutput,
            completion: completion)
    }
    func speakCommandConfirmation(
        _ phrases: [String],
        pauseBetweenPhrases: TimeInterval,
        preservingCurrentOutput: Bool,
        completion: @escaping () -> Void
    ) throws {
        // Optional notices yield even between two streamed sentences.
        if preservingCurrentOutput && hasAnswerOutput { completion(); return }
        cancelConfirmation()
        cancelCue()
        stopListening()
        try audioSession()
        guard allowPhoneAudio || hasBluetoothRoute else {
            throw BridgeError.message("Glasses audio disconnected. The command was received.")
        }

        if preservingCurrentOutput {
            if heartbeatPlayer?.isPlaying == true {
                heartbeatPlayer?.pause()
                resumeHeartbeatAfterConfirmation = true
            }
        } else {
            spokenUtterance = nil
            clearStreamedAnswer()
            synthesizer.stopSpeaking(at: .immediate)
            answerPlayer?.stop()
            answerPlayer = nil
            stopThinkingHeartbeat()
        }

        guard let voice = announcementVoiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:)) else {
            finishConfirmationPlayback()
            completion()
            return
        }
        let phrases = phrases.map(SystemAnnouncement.spokenText).filter { !$0.isEmpty }
        let utterances = phrases.enumerated().map { index, phrase in
            let utterance = AVSpeechUtterance(string: phrase)
            utterance.voice = voice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            if index < phrases.count - 1 { utterance.postUtteranceDelay = pauseBetweenPhrases }
            return utterance
        }
        guard !utterances.isEmpty else {
            finishConfirmationPlayback()
            completion()
            return
        }
        confirmationUtterances = utterances
        confirmationCompletion = completion
        utterances.forEach(confirmationSynthesizer.speak)
    }
    func startThinkingHeartbeat() throws {
        stopThinkingHeartbeat()
        try audioSession()
        let player = try AVAudioPlayer(data: Self.thinkingHeartbeat)
        player.volume = 0.35
        player.numberOfLoops = -1
        player.prepareToPlay()
        heartbeatPlayer = player
        if !player.play() { heartbeatPlayer = nil }
    }
    func stopThinkingHeartbeat() {
        heartbeatPlayer?.stop()
        heartbeatPlayer = nil
    }
    // Speak one finished sentence of an answer that the Mac is still writing.
    // Later sentences queue behind it rather than cutting it off.
    func speakStreamedChunk(_ text: String, listenForCommands commands: Set<VoiceCommand> = []) throws {
        // Only the first sentence of an answer takes over the audio route; the
        // rest queue behind it even if the queue briefly drained.
        let continuing = !streamedAnswerComplete
        if !continuing {
            cancelCue()
            stopThinkingHeartbeat()
            stopListening()
            answerPlayer?.stop()
            answerPlayer = nil
            if synthesizer.isSpeaking {
                spokenUtterance = nil
                synthesizer.stopSpeaking(at: .immediate)
            }
            try audioSession()
            guard allowPhoneAudio || hasBluetoothRoute else {
                throw BridgeError.message("Glasses audio disconnected. The answer is available on screen.")
            }
        }
        streamedAnswerComplete = false
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = selectedVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        if !continuing, !commands.isEmpty { try startCommandListening(for: commands) }
        streamedUtterances.append(utterance)
        synthesizer.speak(utterance)
    }
    // The Mac finished the answer. Listening resumes when the queue drains.
    func finishStreamedAnswer() {
        guard !streamedAnswerComplete else { return }
        streamedAnswerComplete = true
        if streamedUtterances.isEmpty { onFinishedSpeaking?() }
    }
    // The assistant replaced what it was writing, so stop mid-answer and wait.
    func cancelStreamedAnswer() {
        guard !streamedUtterances.isEmpty || !streamedAnswerComplete else { return }
        streamedUtterances.removeAll()
        streamedAnswerComplete = true
        synthesizer.stopSpeaking(at: .immediate)
    }
    func speak(_ text: String, voice: AVSpeechSynthesisVoice? = nil, listenForCommands commands: Set<VoiceCommand> = []) throws {
        cancelCue()
        stopThinkingHeartbeat()
        clearStreamedAnswer()
        stopListening()
        answerPlayer?.stop()
        answerPlayer = nil
        if synthesizer.isSpeaking {
            spokenUtterance = nil
            synthesizer.stopSpeaking(at: .immediate)
        }
        try audioSession()
        guard allowPhoneAudio || hasBluetoothRoute else {
            throw BridgeError.message("Glasses audio disconnected. The answer is available on screen.")
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice ?? selectedVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        if !commands.isEmpty { try startCommandListening(for: commands) }
        noticeUtterance = voice == nil ? nil : utterance
        spokenUtterance = utterance
        synthesizer.speak(utterance)
    }
    func speakAudio(_ data: Data, listenForCommands commands: Set<VoiceCommand> = []) throws {
        cancelCue()
        stopThinkingHeartbeat()
        clearStreamedAnswer()
        stopListening()
        if synthesizer.isSpeaking {
            spokenUtterance = nil
            synthesizer.stopSpeaking(at: .immediate)
        }
        answerPlayer?.stop()
        answerPlayer = nil
        try audioSession()
        guard allowPhoneAudio || hasBluetoothRoute else {
            throw BridgeError.message("Glasses audio disconnected. The answer is available on screen.")
        }
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        if !commands.isEmpty { try startCommandListening(for: commands) }
        player.prepareToPlay()
        answerPlayer = player
        if !player.play() {
            answerPlayer = nil
            throw BridgeError.message("The Kokoro answer audio could not play.")
        }
    }
    func stop() {
        cancelConfirmation()
        clearStreamedAnswer()
        spokenUtterance = nil
        answerPlayer?.stop()
        answerPlayer = nil
        cancelCue()
        stopThinkingHeartbeat()
        stopListening(); synthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    private func playCue(_ data: Data, action: CueAction) throws {
        try audioSession()
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        player.volume = 0.8
        player.prepareToPlay()
        cueAction = action
        cuePlayer = player
        if !player.play() { finishCue() }
    }
    private func finishCue() {
        let action = cueAction
        cueAction = nil
        cuePlayer = nil
        switch action {
        case .startListening:
            do { try startListening(); onStartedListening?() }
            catch { onError?(error.localizedDescription) }
        case .submit(let question): onQuestion?(question)
        case nil: break
        }
    }
    private func clearStreamedAnswer() {
        streamedUtterances.removeAll()
        streamedAnswerComplete = true
    }
    private func cancelCue() {
        cueAction = nil
        cuePlayer?.stop()
        cuePlayer = nil
    }
    func cancelConfirmation() {
        confirmationUtterances.removeAll()
        confirmationCompletion = nil
        resumeHeartbeatAfterConfirmation = false
        confirmationSynthesizer.stopSpeaking(at: .immediate)
    }
    private func finishConfirmation(_ utterance: AVSpeechUtterance) {
        guard let index = confirmationUtterances.firstIndex(where: { $0 === utterance }) else { return }
        confirmationUtterances.remove(at: index)
        guard confirmationUtterances.isEmpty else { return }
        let completion = confirmationCompletion
        confirmationCompletion = nil
        finishConfirmationPlayback()
        completion?()
    }
    private func finishConfirmationPlayback() {
        if resumeHeartbeatAfterConfirmation { heartbeatPlayer?.play() }
        resumeHeartbeatAfterConfirmation = false
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.answerPlayer === player {
                self.answerPlayer = nil
                self.onFinishedSpeaking?()
            } else if self.cuePlayer === player {
                self.finishCue()
            }
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if synthesizer === self.confirmationSynthesizer {
                self.finishConfirmation(utterance)
                return
            }
            if let index = self.streamedUtterances.firstIndex(where: { $0 === utterance }) {
                self.streamedUtterances.remove(at: index)
                // More sentences may still arrive, so wait for the finished answer.
                if self.streamedUtterances.isEmpty, self.streamedAnswerComplete { self.onFinishedSpeaking?() }
                return
            }
            guard self.spokenUtterance === utterance else { return }
            self.spokenUtterance = nil
            self.onFinishedSpeaking?()
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if synthesizer === self.confirmationSynthesizer {
                self.finishConfirmation(utterance)
                return
            }
            // A cancelled sentence never resumes listening by itself.
            self.streamedUtterances.removeAll { $0 === utterance }
        }
    }

    // Generate cues in memory so they cannot go missing from an archive. The
    // rising pair means listening, the falling pair means listening stopped,
    // and the soft double pulse repeats while Codex is working.
    private static let listeningCue = twoNoteCue(first: 660, second: 880)
    private static let stoppedListeningCue = twoNoteCue(first: 880, second: 660)
    private static let thinkingHeartbeat = makeWave(duration: 2.5) { _, time in
        func pulse(start: Double, duration: Double, frequency: Double) -> Double {
            let local = time - start
            guard local >= 0, local < duration else { return 0 }
            let envelope = sin(.pi * local / duration)
            return 0.22 * envelope * sin(2 * .pi * frequency * local)
        }
        return pulse(start: 0, duration: 0.075, frequency: 330) +
            pulse(start: 0.13, duration: 0.09, frequency: 260)
    }
    private static func twoNoteCue(first: Double, second: Double) -> Data {
        var phase = 0.0
        return makeWave(duration: 0.18) { frame, time in
            let progress = time / 0.18
            let frequency = progress < 0.5 ? first : second
            phase += 2.0 * .pi * frequency / 44_100.0
            let attack = min(1.0, Double(frame) / 180.0)
            let frameCount = Int(44_100.0 * 0.18)
            let release = min(1.0, Double(frameCount - frame) / 900.0)
            return 0.32 * min(attack, release) * sin(phase)
        }
    }
    private static func makeWave(duration: Double, sample: (Int, Double) -> Double) -> Data {
        let sampleRate: UInt32 = 44_100
        let frameCount = Int(Double(sampleRate) * duration)
        var samples = Data(capacity: frameCount * 2)
        for frame in 0..<frameCount {
            let time = Double(frame) / Double(sampleRate)
            let value = Int16(Double(Int16.max) * max(-1, min(1, sample(frame, time))))
            append(UInt16(bitPattern: value), to: &samples)
        }

        var wave = Data()
        wave.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + samples.count), to: &wave)
        wave.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16), to: &wave)           // PCM format chunk length
        append(UInt16(1), to: &wave)            // Linear PCM
        append(UInt16(1), to: &wave)            // Mono
        append(sampleRate, to: &wave)
        append(sampleRate * 2, to: &wave)        // Bytes per second
        append(UInt16(2), to: &wave)             // Bytes per frame
        append(UInt16(16), to: &wave)            // Bits per sample
        wave.append(contentsOf: "data".utf8)
        append(UInt32(samples.count), to: &wave)
        wave.append(samples)
        return wave
    }
    private static func append(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
    private static func append(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
