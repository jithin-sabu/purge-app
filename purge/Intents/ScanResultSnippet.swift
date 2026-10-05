import SwiftUI

/// The card Spotlight and Siri show for Scan My Mac. Without it Spotlight shows
/// only the returned size ("1.58 GB"), which says nothing about what it is.
/// System fonts and colors only: the card is drawn by Spotlight, not Purge.
struct ScanResultSnippet: View {
    let outcome: IntentRouter.ScanOutcome

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.title2.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var headline: String {
        switch outcome {
        case .scanned(let bytes) where bytes > 0: return "\(formatBytes(bytes)) safe to clean"
        case .scanned: return "Nothing to clean"
        case .needsSetup: return "Finish setting up Purge"
        case .busyCleaning: return "Purge is cleaning"
        case .stopped: return "Scan stopped"
        }
    }

    private var detail: String {
        switch outcome {
        case .scanned(let bytes) where bytes > 0:
            return "Found in App Caches and Dev Tools. Nothing has been cleaned yet."
        case .scanned: return "App Caches and Dev Tools have nothing safe to clean right now."
        case .needsSetup: return "Purge is open. Finish setup there, then scan again."
        case .busyCleaning: return "Scan again when the clean finishes."
        case .stopped: return "The scan ended before App Caches and Dev Tools finished."
        }
    }

    private var symbol: String {
        switch outcome {
        case .scanned(let bytes) where bytes > 0: return "sparkles"
        case .scanned: return "checkmark.circle.fill"
        case .needsSetup, .busyCleaning, .stopped: return "exclamationmark.circle.fill"
        }
    }

    private var tint: Color {
        switch outcome {
        case .scanned: return .accentColor
        case .needsSetup, .busyCleaning, .stopped: return .orange
        }
    }
}
