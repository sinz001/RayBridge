import Foundation

// Where a question's picture comes from. The glasses remain the default; the
// iPhone camera and speaker let someone use RayBridge without glasses at all.
enum CaptureSource: String, CaseIterable, Identifiable {
    case glasses
    case phone
    var id: String { rawValue }
    var displayName: String { self == .glasses ? "Meta glasses" : "This iPhone" }
    // Without glasses there is no Bluetooth headset route, so answers, cues and
    // confirmations play through the iPhone regardless of the testing toggle.
    var requiresPhoneAudio: Bool { self == .phone }
    var startingStatus: String {
        self == .glasses ? "안경 카메라 연결 중" : "아이폰 카메라 준비 중"
    }
    var connectedStatus: String {
        self == .glasses ? "안경 카메라 연결됨" : "아이폰 카메라 연결됨"
    }
    var cameraReadyAnnouncement: String {
        self == .glasses
            ? "안경 카메라가 연결됐어요. 질문해 주세요."
            : "아이폰 카메라가 켜졌어요. 후면 카메라로 대상을 비추고 질문해 주세요."
    }
}

// What a quick, synchronous check of the Meta SDK says about the glasses before
// startup begins. It is a hint for the warning text, not a substitute for the
// full camera startup, so every warning also offers to try the glasses anyway.
enum GlassesReadiness: Equatable {
    case ready
    case discoveryUnavailable
    case notRegistered
    case noGlassesFound
    case notConnected
    case connecting
    case needsUpdate
}

// The startup steps `SessionController` runs, mirrored here so the policy and
// its tests stay free of the session and hardware types.
enum StartupStage: Equatable {
    case connecting
    case authorizing
    case startingCamera
    case startingAudio
    case other
}

enum GlassesWarningAction: Equatable {
    case continueWithoutGlasses
    case tryGlassesAnyway
    case openSetup
    case cancel
}

struct GlassesWarning: Equatable, Identifiable {
    let title: String
    let message: String
    // Spoken after the warning appears, unless an error is already being read.
    let spokenNotice: String
    let actions: [GlassesWarningAction]
    var id: String { title + message }
}

enum StartDecision: Equatable {
    case startWithGlasses
    case startWithPhone
    case warnBeforePhone(GlassesReadiness)
}

enum BackgroundSessionAction: Equatable {
    case continueGlassesSession
    case continuePhoneCameraSession
    case continuePhoneAudioSession
    case preservePermissionHandoff
    case stopStandbyListening
}

enum CaptureSourcePolicy {
    static let phoneFallbackOffer =
        "안경 없이 아이폰 카메라와 스피커로 계속할 수 있어요."

    static func decision(preferred: CaptureSource, glasses: GlassesReadiness) -> StartDecision {
        // Someone who chose the iPhone in Setup never has to answer for glasses.
        guard preferred == .glasses else { return .startWithPhone }
        return glasses == .ready ? .startWithGlasses : .warnBeforePhone(glasses)
    }

    static func warning(for readiness: GlassesReadiness) -> GlassesWarning {
        GlassesWarning(
            title: "안경이 연결되지 않았어요",
            message: "\(reason(readiness)) \(phoneFallbackOffer)",
            spokenNotice: "\(reason(readiness)) 아이폰으로 계속하려면 Start, 돌아가려면 Cancel이라고 말해 주세요.",
            actions: readiness == .notRegistered
                ? [.continueWithoutGlasses, .openSetup, .cancel]
                : [.continueWithoutGlasses, .tryGlassesAnyway, .cancel])
    }

    // Offered after the glasses camera or glasses audio fails to start. The
    // failure has already been spoken, so this warning stays silent.
    static func startupFailureWarning(_ message: String) -> GlassesWarning {
        GlassesWarning(
            title: "안경을 사용할 수 없어요",
            message: "\(message) \(phoneFallbackOffer)",
            spokenNotice: "",
            actions: [.continueWithoutGlasses, .tryGlassesAnyway, .cancel])
    }

    // A Mac connection or iPhone permission failure is not fixed by dropping the
    // glasses, so only the glasses-specific startup steps offer the iPhone.
    static func offersPhoneFallback(failedStage: StartupStage, source: CaptureSource) -> Bool {
        guard source == .glasses else { return false }
        return failedStage == .startingCamera || failedStage == .startingAudio
    }

    static func backgroundAction(
        sessionActive: Bool,
        source: CaptureSource,
        awaitingGlassesPermission: Bool,
        phoneCameraSupportsBackground: Bool = false
    ) -> BackgroundSessionAction {
        if awaitingGlassesPermission { return .preservePermissionHandoff }
        guard sessionActive else { return .stopStandbyListening }
        if source == .glasses { return .continueGlassesSession }
        return phoneCameraSupportsBackground ? .continuePhoneCameraSession : .continuePhoneAudioSession
    }

    private static func reason(_ readiness: GlassesReadiness) -> String {
        switch readiness {
        case .ready: return "안경이 준비됐어요."
        case .discoveryUnavailable: return "안경을 검색할 수 없어요."
        case .notRegistered: return "먼저 메타 AI 앱에 안경을 등록해 주세요."
        case .noGlassesFound: return "안경을 찾을 수 없어요."
        case .notConnected: return "안경이 연결되지 않았어요."
        case .connecting: return "안경을 연결하고 있어요."
        case .needsUpdate: return "안경이나 앱을 업데이트해 주세요."
        }
    }
}
