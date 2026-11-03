import AppKit
import SwiftUI

/// The search capsule in the Large Files and Uninstall controls rows. It draws
/// its own focus border, clears on Escape, and answers Edit > Find (#185).
struct CapsuleSearchField: View {
    @Binding var query: String
    let prompt: LocalizedStringKey
    let accessibilityLabel: LocalizedStringKey
    let width: CGFloat

    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Local mouse-down monitor installed only while the field is focused; see
    /// `installOutsideClickResign`.
    @State private var outsideClickMonitor: Any?
    /// Set by Edit > Find when the field was not focused: the selection has to wait
    /// for `isFocused` to land, or it would run before AppKit has a field editor.
    @State private var selectsAllOnFocus = false

    /// Matches FilterChip's metrics so the row's controls share a baseline.
    private static let horizontalPadding: CGFloat = AppStyle.Spacing.small
    private static let verticalPadding: CGFloat = AppStyle.Spacing.xxSmallPlus

    private var hasText: Bool { !query.isEmpty }

    var body: some View {
        HStack(spacing: AppStyle.Spacing.xxSmallPlus) {
            Image(systemName: "magnifyingglass")
                .imageScale(.small)
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)

            TextField(prompt, text: $query)
                .textFieldStyle(.plain)
                .font(AppStyle.Typography.body)
                .foregroundStyle(AppColors.textPrimary)
                .focused($isFocused)
                .focusEffectDisabledIfAvailable()
                .accessibilityLabel(accessibilityLabel)
                // Escape clears rather than just unfocusing: an emptied field is the
                // state the user wants back, and it's the one AppKit search fields
                // give them.
                .onExitCommand {
                    if hasText {
                        query = ""
                    } else {
                        isFocused = false
                    }
                }

            // A real Button is fine here — unlike the result rows, this field lives
            // in the controls chrome and never inside the List, so it can't trigger
            // the scroll-to-clicked-row behaviour that forces rows to use tap gestures.
            if hasText {
                Button {
                    query = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(AppColors.textTertiary)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .help("Clear search")
                .accessibilityLabel("Clear search")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, Self.verticalPadding)
        .frame(width: width)
        .background {
            Capsule(style: .continuous)
                .fill(AppColors.fillSecondary)
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(
                    isFocused ? AppColors.actionPrimary : AppColors.borderSubtle,
                    lineWidth: 1
                )
        }
        .contentShape(Capsule(style: .continuous))
        // Clicking anywhere in the capsule focuses the field, not just the glyph-width
        // of text already typed.
        .onTapGesture { isFocused = true }
        .focusedSceneValue(\.findAction, FindAction {
            if isFocused {
                FindAction.selectAllInFieldEditor()
            } else {
                selectsAllOnFocus = true
                isFocused = true
            }
        })
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isFocused)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: hasText)
        .onChange(of: isFocused) { focused in
            if focused {
                installOutsideClickResign()
                if selectsAllOnFocus { FindAction.selectAllInFieldEditor() }
            } else {
                removeOutsideClickResign()
            }
            selectsAllOnFocus = false
        }
        .onDisappear { removeOutsideClickResign() }
    }

    /// Clicks outside this capsule must drop focus, but SwiftUI leaves a focused
    /// TextField's first responder in place when the click lands on anything
    /// non-focusable — list rows, buttons, empty space — which is why the capsule
    /// border used to stick around. While focused, a local monitor resigns first
    /// responder for any mouse-down that didn't land on the field editor itself.
    private func installOutsideClickResign() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window,
                  let hitView = window.contentView?.hitTest(event.locationInWindow),
                  hitView !== window.firstResponder
            else { return event }
            window.makeFirstResponder(nil)
            return event
        }
    }

    private func removeOutsideClickResign() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }
}

private extension View {
    /// Suppresses the system focus ring on the search field (macOS 14+); a no-op on
    /// older systems. The field draws its own capsule border on focus, and the ring
    /// drawn on top of it stayed after the field lost focus.
    @ViewBuilder
    func focusEffectDisabledIfAvailable() -> some View {
        if #available(macOS 14.0, *) {
            focusEffectDisabled()
        } else {
            self
        }
    }
}
