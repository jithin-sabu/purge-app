import SwiftUI

/// The size line, Cancel and the destructive confirm button that end each removal
/// sheet. The confirm button is off while nothing is picked, so no sheet offers
/// "Move 0 to Trash" (#185).
struct RemovalSheetFooter: View {
    let sizeLine: String
    var cancelTitle: LocalizedStringKey = "Cancel"
    let confirmTitle: String
    let itemCount: Int
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack(spacing: AppStyle.Spacing.small) {
            Text(sizeLine)
                .font(AppStyle.Typography.metadataEmphasis.numbers)
                .foregroundStyle(AppColors.textSecondary)

            Spacer()

            Button(cancelTitle, action: onCancel)
                .buttonStyle(.purge(.secondary))
                .keyboardShortcut(.cancelAction)

            Button(confirmTitle, action: onConfirm)
                .buttonStyle(.purge(.destructive))
                .keyboardShortcut(.defaultAction)
                .disabled(itemCount == 0)
        }
    }
}
