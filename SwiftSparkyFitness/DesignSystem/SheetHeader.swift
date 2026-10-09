//
//  SheetHeader.swift
//  SwiftSparkyFitness
//
//  The Cancel / title / action bar every sheet in the app wears.
//
//  Each sheet used to hand-build this, which drifted in two ways worth
//  knowing about:
//
//  1. The title sat between two `Spacer()`s, so it centred itself in the
//     space *left over* by the two buttons rather than on the screen. With a
//     "Cancel" on one side and a "Save" on the other the widths differ, and
//     the title landed up to 6pt off centre. Here it's a centred overlay on
//     the full bar, so it's centred on the sheet whatever flanks it.
//  2. Tap targets were whatever the text happened to measure (~45x17pt).
//
//  The trailing action is a *value*, not a `@ViewBuilder` slot, and that is
//  deliberate. The first version of this took a view, and the very first
//  sheet built on it shipped a 42x16pt Send button — a caller-supplied view
//  can't be forced to fill the 44pt box reserved for it, so the guarantee
//  quietly became a convention and the convention was immediately broken.
//  Describing the button instead means the 44pt target, the disabled colour
//  and the press style are applied here, once, and no sheet can opt out.
//
//  The buttons are Liquid Glass circles — ✕ to leave, a tinted ✓ to confirm —
//  as iOS's own sheets draw them. They were 15pt words: a target only as
//  wide as the word, with nothing drawn to say where it was, tucked under
//  the grabber. The circle is the whole target, and the word lives on as
//  the VoiceOver label.
//

import SwiftUI

/// The trailing button in a sheet header — "Save", "Add", "Send".
struct SheetAction {
    let title: String
    var isEnabled: Bool = true
    /// Swaps the title for a spinner and refuses taps. Several sheets make
    /// more than one sequential call on save, which left the button looking
    /// tappable for seconds — long enough for a second tap to write a
    /// duplicate entry.
    var isBusy: Bool = false
    let perform: () -> Void

    init(_ title: String, isEnabled: Bool = true, isBusy: Bool = false, perform: @escaping () -> Void) {
        self.title = title
        self.isEnabled = isEnabled
        self.isBusy = isBusy
        self.perform = perform
    }
}

struct SheetHeader: View {
    let title: String
    var cancelTitle: String = "Cancel"
    /// ✕ closes; a detail slid over a list goes back with a chevron instead.
    var cancelSymbol: String = "xmark"
    let onCancel: () -> Void
    var action: SheetAction? = nil
    /// Log Food's header is the title bar *plus* a search field and meal
    /// chips, and the rule below all of that is the one that separates the
    /// header from the results. A second rule under just the title would cut
    /// the block in half.
    var showsDivider: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onCancel) {
                symbol(cancelSymbol)
                    .foregroundStyle(AppColor.ink)
            }
            .sheetButtonStyle(prominent: false)
            .accessibilityLabel(cancelTitle)

            Spacer(minLength: 0)

            if let action {
                let isEnabled = action.isEnabled && !action.isBusy
                Button(action: action.perform) {
                    if action.isBusy {
                        ProgressView().tint(.white).frame(width: Self.symbolSide, height: Self.symbolSide)
                    } else {
                        symbol("checkmark")
                    }
                }
                .sheetButtonStyle(prominent: true)
                .tint(AppColor.accent)
                .disabled(!isEnabled)
                // While busy the label is a bare spinner, which VoiceOver read
                // as an unnamed button; it keeps its title and says it's working.
                .accessibilityLabel(action.title)
                .accessibilityValue(action.isBusy ? "In progress" : "")
            }
        }
        .buttonBorderShape(.circle)
        .overlay {
            // Centred on the bar, not on the gap between the buttons. Inset
            // past the circles plus a 12pt gap (it was 72pt, ~7pt clear of
            // them). A long exercise name shrinks a little before it
            // truncates.
            if !title.isEmpty {
                Text(title)
                    .appDisplay(18)
                    .foregroundStyle(AppColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .allowsTightening(true)
                    .padding(.horizontal, Self.titleInset)
                    .accessibilityAddTraits(.isHeader)
                    .allowsHitTesting(false)
            }
        }
        // Where the system puts toolbar buttons in a sheet (measured against
        // Goals' native toolbar): 16pt in from the side and the top — clear of
        // the grabber, whose drag competed with buttons pressed up against
        // it, and the same distance from both edges of the rounded corner.
        .padding(.horizontal, Self.edgeInset)
        .padding(.top, Self.edgeInset)
        .padding(.bottom, 10)
        // Bar and buttons stop growing where nav bars do; past it the glass
        // grew round shrinking ✕/✓ glyphs and the title filled the bar.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle().fill(AppColor.hairline).frame(height: 1)
            }
        }
    }

    /// With the glass's own padding this draws a ~45pt circle.
    private static let symbolSide: CGFloat = 32
    private static let edgeInset: CGFloat = 16
    private static let titleInset: CGFloat = edgeInset + 45 + 12

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .semibold))
            .frame(width: Self.symbolSide, height: Self.symbolSide)
    }
}

private extension View {
    /// Liquid Glass circles from iOS 26; before it, the bordered circles
    /// iOS 17 drew for the same job.
    @ViewBuilder func sheetButtonStyle(prominent: Bool) -> some View {
        if #available(iOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}
