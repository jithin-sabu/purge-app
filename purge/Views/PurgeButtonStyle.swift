import SwiftUI

/// The one button style for every action in Purge.
///
/// - Roles: `.primary` is the one main action on a screen or sheet. `.secondary`
///   is every other action (Cancel, Scan). `.destructive` confirms a move to
///   Trash. `.quiet` is an inline, low-weight action.
/// - Sizes: `.small` (24pt) for rows and notices, `.regular` (30pt) for the
///   toolbar, sheets and Settings, `.large` (38pt) for onboarding and the
///   cleanup celebration.
///
/// Every action is a pill (an icon-only button is the square-width case, a
/// circle). Controls that hold a value (pickers, fields,
/// segmented controls) use a rounded rectangle instead, so shape alone tells an
/// action from a setting.
struct PurgeButtonStyle: ButtonStyle {
    enum Role {
        case primary
        case secondary
        case destructive
        case quiet
    }

    enum Size {
        case small
        case regular
        case large
    }

    enum Width {
        /// Hug the label.
        case fit
        /// Stretch to the available width.
        case fill
        /// A fixed width, for stacked actions that should line up (onboarding).
        case fixed(CGFloat)
        /// As wide as it is tall, so the pill becomes a circle. For icon-only
        /// buttons: give the label a `Label` with `.labelStyle(.iconOnly)` so
        /// VoiceOver still reads its title, and a `.help` tooltip.
        case square
    }

    var role: Role = .secondary
    var size: Size = .regular
    var width: Width = .fit

    func makeBody(configuration: Configuration) -> some View {
        PurgeButtonBody(configuration: configuration, role: role, size: size, width: width)
    }
}

extension ButtonStyle where Self == PurgeButtonStyle {
    static func purge(
        _ role: PurgeButtonStyle.Role = .secondary,
        size: PurgeButtonStyle.Size = .regular,
        width: PurgeButtonStyle.Width = .fit
    ) -> PurgeButtonStyle {
        PurgeButtonStyle(role: role, size: size, width: width)
    }
}

private struct PurgeButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let role: PurgeButtonStyle.Role
    let size: PurgeButtonStyle.Size
    let width: PurgeButtonStyle.Width

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        sizedLabel
            .font(font)
            .foregroundStyle(foreground)
            .tint(foreground)
            .lineLimit(1)
            .padding(.horizontal, isSquare ? 0 : horizontalPadding)
            .frame(height: height)
            .background(background, in: Capsule(style: .continuous))
            .overlay {
                if let border {
                    Capsule(style: .continuous)
                        .strokeBorder(border, lineWidth: 1)
                }
            }
            .contentShape(Capsule(style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: isEnabled)
    }

    @ViewBuilder
    private var sizedLabel: some View {
        switch width {
        case .fit:
            configuration.label
        case .fill:
            configuration.label.frame(maxWidth: .infinity)
        case .fixed(let value):
            configuration.label.frame(width: max(0, value - horizontalPadding * 2))
        case .square:
            configuration.label.frame(width: height)
        }
    }

    private var isSquare: Bool {
        if case .square = width { return true }
        return false
    }

    private var height: CGFloat {
        switch size {
        case .small: 24
        case .regular: 30
        case .large: 38
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .small: 10
        case .regular: 14
        case .large: 20
        }
    }

    private var font: Font {
        switch size {
        case .small: AppStyle.Typography.callout.weight(.semibold)
        case .regular: AppStyle.Typography.headline
        case .large: AppStyle.Typography.sectionTitle
        }
    }

    private var isActive: Bool { isEnabled && isHovering }

    private var foreground: Color {
        switch role {
        case .primary: AppColors.onActionPrimary
        case .secondary: AppColors.textPrimary
        case .destructive: .white
        case .quiet: isActive ? AppColors.textPrimary : AppColors.textSecondary
        }
    }

    private var background: Color {
        let pressed = configuration.isPressed
        switch role {
        case .primary:
            return pressed ? AppColors.actionPrimaryPressed : (isActive ? AppColors.actionPrimaryHover : AppColors.actionPrimary)
        case .secondary:
            return pressed ? AppColors.fillSecondaryPressed : (isActive ? AppColors.fillSecondaryHover : AppColors.fillSecondary)
        case .destructive:
            return pressed ? AppColors.actionDestructivePressed : (isActive ? AppColors.actionDestructiveHover : AppColors.actionDestructive)
        case .quiet:
            return pressed ? AppColors.fillSecondaryPressed : (isActive ? AppColors.fillSecondaryHover : .clear)
        }
    }

    private var border: Color? {
        role == .secondary ? AppColors.borderStrong : nil
    }
}
