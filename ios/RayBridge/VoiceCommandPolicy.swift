import Foundation

enum VoiceCommand: String, CaseIterable, Hashable {
    case start
    case stop
    case cancel
    case mute
    case unmute
    case status
    case `repeat`
    case commands
}

// Commands must be short standalone utterances. This keeps phrases such as
// “Where is the bus stop?” and “How do I mute this?” available as questions.
enum VoiceCommandPolicy {
    static let launchAnnouncement =
        "시작 버튼을 누르거나 Start라고 말해 주세요. 명령어를 들으려면 Commands라고 말하세요."

    static let helpAnnouncementPhrases = [
        "시작하려면 Start.",
        "종료하려면 Stop.",
        "현재 요청을 취소하려면 Cancel.",
        "진행 상황은 Status.",
        "마지막 답변을 다시 들으려면 Repeat.",
        "음성 입력을 끄려면 Mute.",
        "다시 켜려면 Unmute.",
        "명령어를 다시 들으려면 Commands."
    ]

    static let helpAnnouncement = helpAnnouncementPhrases.joined(separator: " ")

    private static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    static func command(in text: String) -> VoiceCommand? {
        guard words(text).count == 1 else { return nil }
        return words(text).first.flatMap(VoiceCommand.init(rawValue:))
    }
}
