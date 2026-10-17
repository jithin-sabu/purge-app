import SwiftUI

/// The Map side of the drill-in (#220). Lands in the next commit; until then the
/// card names the level the list has open, so the switch already works.
struct EverythingElseMapCard: View {
    let breakdown: EverythingElseBreakdown
    @Binding var openGroup: EverythingElseGroup?
    @Binding var selectedFolderPath: String?
    let linkedState: (String) -> OverviewLinkedRowState

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
            Text(openGroup.map(EverythingElseStyle.name) ?? String(localized: "Everything else"))
                .font(AppStyle.Typography.headline)
            Text("The map is on its way.")
                .font(AppStyle.Typography.callout)
                .foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppStyle.Spacing.medium)
        .overviewCard()
    }
}
