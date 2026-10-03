//
//  DiscardGuard.swift
//  SwiftSparkyFitness
//
//  "Discard changes?" for every screen that edits data. One modifier, so
//  the wording and the two exits behave the same everywhere:
//
//  * Cancel / Back: the screen sets `isPresented` when `isDirty`, and
//    dismisses straight away when nothing changed.
//  * Swipe-down on a sheet: iOS 27's `dismissalConfirmationDialog` asks the
//    same question when `isDirty`; earlier, the swipe is blocked instead.
//
//  "Keep Editing" leaves the screen as it was; "Discard Changes" closes it.
//

import SwiftUI

extension View {
    /// `isDirty` is whether there is anything to lose. `isPresented` is the
    /// screen's own flag, set by its Cancel/Back button via `requestExit`.
    func discardGuard(isDirty: Bool, isPresented: Binding<Bool>, discard: @escaping () -> Void) -> some View {
        modifier(DiscardGuard(isDirty: isDirty, isPresented: isPresented, discard: discard))
    }
}

private struct DiscardGuard: ViewModifier {
    let isDirty: Bool
    @Binding var isPresented: Bool
    let discard: () -> Void

    func body(content: Content) -> some View {
        let guarded = content
            .confirmationDialog("Discard your changes?", isPresented: $isPresented, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive, action: discard)
                Button("Keep Editing", role: .cancel) {}
            }
        if #available(iOS 27, *) {
            guarded.dismissalConfirmationDialog("Discard your changes?", shouldPresent: isDirty) {
                Button("Discard Changes", role: .destructive, action: discard)
            }
        } else {
            // No swipe-down prompt before iOS 27: block the swipe while there
            // are edits, so Cancel (which asks) is the only way out.
            guarded.interactiveDismissDisabled(isDirty)
        }
    }
}
