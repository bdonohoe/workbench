import BenchKit
import Foundation

/// Turns what the phone sends to the Mac into analytics events. Only the
/// kind of action is counted, never what was typed or which session.
enum PhoneAnalytics {
    static func log(_ message: ClientMessage) {
        switch message {
        case .reply:
            Analytics.capture(.replySent, ["with_images": false])
        case .replyWithAttachments:
            Analytics.capture(.replySent, ["with_images": true])
        case .answer(_, let allow):
            Analytics.capture(.toolAnswered, ["allowed": allow])
        case .answerQuestions(_, let answers):
            Analytics.capture(.questionAnswered, ["count": answers.count])
        default:
            break
        }
    }
}
