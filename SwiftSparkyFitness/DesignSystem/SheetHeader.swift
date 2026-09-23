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

import SwiftUI

/// The trailing button in a sheet header — "Save", "Add", "Send".
struct SheetAction {
    let title: String
    var isEnabled: Bool = true
    let perform: () -> Void

    init(_ title: String, isEnabled: Bool = true, perform: @escaping () -> Void) {
        self.title = title
        self.isEnabled = isEnabled
        self.perform = perform
    }
}

struct SheetHeader: View {
    let title: String
    var cancelTitle: String = "Cancel"
    let onCancel: () -> Void
    var action: SheetAction? = nil

    var body: some View {
        HStack(spacing: 8) {
            button(
                title: cancelTitle,
                tint: AppColor.secondaryText,
                weight: .regular,
                alignment: .leading,
                isEnabled: true,
                perform: onCancel
            )

            Spacer(minLength: 0)

            if let action {
                button(
                    title: action.title,
                    tint: action.isEnabled ? AppColor.accent : AppColor.placeholder,
                    weight: .semibold,
                    alignment: .trailing,
                    isEnabled: action.isEnabled,
                    perform: action.perform
                )
            }
        }
        .overlay {
            // Centred on the bar, not on the gap between the buttons. Padded
            // so a long title truncates rather than sliding under them.
            Text(title)
                .appDisplay(18)
                .foregroundStyle(AppColor.ink)
                .lineLimit(1)
                .padding(.horizontal, 72)
                .accessibilityAddTraits(.isHeader)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, AppSpacing.screenPad)
        .overlay(Rectangle().fill(AppColor.hairline).frame(height: 1), alignment: .bottom)
    }

    /// The 44pt target lives on the *label*, not on the Button — a frame
    /// applied outside the button grows the layout slot without growing the
    /// region that actually accepts a touch.
    private func button(
        title: String,
        tint: Color,
        weight: Font.Weight,
        alignment: Alignment,
        isEnabled: Bool,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Text(title)
                .appBody(15, weight: weight)
                .foregroundStyle(tint)
                .frame(minWidth: 44, minHeight: 44, alignment: alignment)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(!isEnabled)
    }
}
