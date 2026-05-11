import AppKit
import SwiftUI

struct PermissionPromptView: View {
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)

            Text("Full Disk Access Needed")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Purge needs Full Disk Access to scan and clean caches in your home directory.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)

            HStack {
                Button("Open Privacy Settings") {
                    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else {
                        return
                    }
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.borderedProminent)

                Button("I've Granted Access", action: onRefresh)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
