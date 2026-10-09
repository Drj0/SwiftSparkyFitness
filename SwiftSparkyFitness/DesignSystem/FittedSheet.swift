//
//  FittedSheet.swift
//  SwiftSparkyFitness
//
//  Sheets as tall as what's in them. A form sheet's body is a ScrollView,
//  which takes whatever height it's offered — so a fixed `.medium`/`.large`
//  left Yoga's two fields under half a screen of blank sheet, and a long
//  Strength log cramped. The parts that make up the content's height mark
//  themselves with `sheetHeightPart()` (header and the scroll's content);
//  the presenter's `fittedDetent()` sizes the sheet to their sum, and the
//  system caps it at full height. Nothing marked: full height, for lists.
//
//  Not inside a NavigationStack: once a screen was pushed in the sheet, the
//  sheet stopped following detent changes at all. Log Food and Log Exercise
//  slide their detail over the list by hand for this.
//

import SwiftUI

private struct SheetHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

extension Animation {
    /// The sheet's resize, and the slide between a list and its detail —
    /// one curve, so the content and the sheet edge move as one piece.
    static let sheetResize = Animation.smooth(duration: 0.38)
}

private struct FittedDetent: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var detents: Set<PresentationDetent> = [.large]
    @State private var selection: PresentationDetent = .large

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(SheetHeightKey.self) { height in
                let fitted: PresentationDetent = height > 0 ? .height(height.rounded(.up)) : .large
                Task { @MainActor in await move(to: fitted) }
            }
            .presentationDetents(detents, selection: $selection)
    }

    /// Swapping the detent set and the selection in one update snapped the
    /// sheet to its new height in a single frame. So: add the new height
    /// beside the current one, move to it animated a frame later (a move
    /// within the set is what animates), then drop the old one once the
    /// sheet has settled so it can't be dragged back to.
    ///
    /// Run a turn after the preference change, not during it: set during
    /// the detail's slide-out, going back to full height was dropped.
    private func move(to fitted: PresentationDetent) async {
        guard fitted != selection else { return }
        detents.insert(fitted)
        try? await Task.sleep(for: .milliseconds(16))
        withAnimation(reduceMotion ? nil : .sheetResize) { selection = fitted }
        try? await Task.sleep(for: .milliseconds(450))
        if selection == fitted { detents = [fitted] }
    }
}

extension View {
    /// Counts this view's natural height toward its sheet's height.
    func sheetHeightPart() -> some View {
        background(GeometryReader { Color.clear.preference(key: SheetHeightKey.self, value: $0.size.height) })
    }

    /// Stops this view's `sheetHeightPart()`s counting, from the moment
    /// `ignored` turns true. A detail on its way out still reports its height
    /// until its slide ends; this lets the sheet start growing back on the
    /// tap instead.
    func sheetHeightIgnored(_ ignored: Bool) -> some View {
        transformPreference(SheetHeightKey.self) { if ignored { $0 = 0 } }
    }

    /// Sizes the sheet to its content's `sheetHeightPart()`s.
    func fittedDetent() -> some View {
        modifier(FittedDetent())
    }
}
