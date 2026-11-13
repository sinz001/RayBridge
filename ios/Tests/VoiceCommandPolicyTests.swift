import Foundation

@main
struct VoiceCommandPolicyTests {
    static func main() {
        let commands: [(String, VoiceCommand)] = [
            ("Start!", .start),
            (" STOP ", .stop),
            ("Cancel.", .cancel),
            ("MUTE", .mute),
            ("unmute", .unmute),
            ("Status?", .status),
            ("Repeat.", .repeat),
            ("Commands!", .commands)
        ]
        for (text, expected) in commands {
            precondition(VoiceCommandPolicy.command(in: text) == expected, "Missed command: \(text)")
        }

        for text in [
            "", "please stop", "cancel that", "mute please", "unmute now", "show commands",
            "task status", "repeat that",
            "nonstop", "stopping", "started", "muted", "stopwatch",
            "Where is the bus stop?", "How do I mute this?", "Start the timer"
        ] {
            precondition(VoiceCommandPolicy.command(in: text) == nil, "Lost question: \(text)")
        }
        precondition(VoiceCommandPolicy.launchAnnouncement.contains("시작 버튼"))
        precondition(VoiceCommandPolicy.launchAnnouncement.contains("Start라고"))
        precondition(VoiceCommandPolicy.helpAnnouncementPhrases.count == VoiceCommand.allCases.count,
                     "Help should give every command its own paused phrase")
        for command in VoiceCommand.allCases {
            precondition(VoiceCommandPolicy.helpAnnouncement.localizedCaseInsensitiveContains(command.rawValue),
                         "Help must announce the \(command.rawValue) command")
        }
        precondition(SystemAnnouncement.spokenText("준비...   중…") == "준비 중")
        precondition(SystemAnnouncement.spokenText(" . . . … ") == "")
        precondition(SystemAnnouncement.spokenText("버전 1.5를 확인했어요.") == "버전 1.5를 확인했어요.")
        precondition(SystemAnnouncement.coordinator("The assistant is working on your question.").contains("작업"))
        precondition(SystemAnnouncement.coordinator("...") == "")
        precondition(SystemAnnouncement.coordinator("파일을 확인했어요…") == "파일을 확인했어요")
        precondition(!SystemAnnouncement.error("An unexpected SDK error: ...").contains("SDK"))
        print("Passed voice command matching and question preservation tests.")
    }
}
