import Foundation

/// The one-line answers Spotlight shows for Purge's actions.
enum IntentAnswer {
    /// `text` with the size `bytes` names in bold.
    static func bolding(_ bytes: Int64, in text: String) -> AttributedString {
        var answer = AttributedString(text)
        if let sizeRange = answer.range(of: formatBytes(bytes)) {
            answer[sizeRange].inlinePresentationIntent = .stronglyEmphasized
        }
        return answer
    }
}
