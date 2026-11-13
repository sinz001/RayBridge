import Foundation

enum SystemAnnouncement {
    static let missingVoice = "한국어 안내 음성을 사용하려면 아이폰 설정의 손쉬운 사용에서 한국어 음성을 다운로드한 뒤 앱 설정을 다시 열어 주세요."

    // Only clean app announcements. Pauses, punctuation and formatting in an
    // assistant's answer (including Repeat) belong to the answer.
    static func spokenText(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(of: #"(?:\.\s*){3,}|…+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.contains(where: { $0.isLetter || $0.isNumber }) ? cleaned : ""
    }

    // Mac bridges also send free-form agent progress. Give a brief Korean update
    // when the progress itself is not in Korean.
    static func coordinator(_ text: String) -> String {
        switch text {
        case "Got it. I’ll start now and keep you updated.": return "답변을 준비하고 있어요."
        case "I’m still working on your request.", "The assistant is working on your question.": return "아직 작업 중이에요."
        case "Cancellation is still in progress.": return "취소하고 있어요."
        case "The task is starting.": return "작업을 시작하고 있어요."
        case "No task is running. RayBridge is listening.": return "질문을 기다리고 있어요."
        case "There is no completed answer to repeat yet.": return "아직 다시 들을 답변이 없어요."
        default:
            let cleaned = spokenText(text)
            guard !cleaned.isEmpty else { return "" }
            return containsKorean(cleaned) ? cleaned : "작업을 진행하고 있어요."
        }
    }

    private static func containsKorean(_ text: String) -> Bool {
        text.range(of: #"[가-힣]"#, options: .regularExpression) != nil
    }

    // SDK and remote errors can include paths, URLs or arbitrary diagnostics.
    // Leave those on screen. Speak the recovery action for known failures.
    static func error(_ detail: String) -> String {
        if containsKorean(detail) { return spokenText(detail) }
        let text = detail.lowercased()
        if text.contains("sign in") || text.contains("login") { return "맥에서 선택한 AI에 로그인해 주세요." }
        if text.contains("mac did not answer") || text.contains("connection to the mac") {
            return "맥과 연결할 수 없어요. 맥에서 레이브릿지가 열려 있는지, 네트워크가 연결됐는지 확인해 주세요."
        }
        if text.contains("pair") { return "설정에서 맥 페어링을 확인해 주세요." }
        if text.contains("allow speech recognition") { return "아이폰 설정에서 음성 인식을 허용해 주세요." }
        if text.contains("on-device english") { return "영어 음성 명령을 사용할 수 없어요. 설정에서 음성 명령을 끄고 다시 시도해 주세요." }
        if text.contains("allow microphone") { return "아이폰 설정에서 마이크 사용을 허용해 주세요." }
        if text.contains("allow glasses camera") { return "메타 AI 앱에서 안경 카메라 사용을 허용해 주세요." }
        if text.contains("allow camera") { return "아이폰 설정에서 카메라 사용을 허용해 주세요." }
        if text.contains("register") || text.contains("registration") { return "메타 AI 앱에서 안경 등록을 확인해 주세요." }
        if text.contains("glasses") || text.contains("bluetooth") { return "안경 연결을 확인하고 다시 시도해 주세요." }
        if text.contains("camera") || text.contains("image") { return "카메라를 확인하고 다시 시도해 주세요." }
        if text.contains("microphone") { return "마이크 연결을 확인해 주세요." }
        if text.contains("audio") || text.contains("voice preview") { return "소리를 재생할 수 없어요. 오디오 연결을 확인해 주세요." }
        if text.contains("cancel") { return "취소를 확인할 수 없어요. 맥에 다시 연결해 주세요." }
        return "오류가 발생했어요. 화면에서 자세한 내용을 확인해 주세요."
    }
}
