//
//  TabBar.swift
//  SwiftSparkyFitness
//
//  The four tabs. The bar itself is the system's now — see MainTabView for
//  why the hand-rolled one went.
//
//  THE DESIGN'S RINGED ICONS, AS REAL SYMBOLS
//  ------------------------------------------
//  The design draws each tab as a stroked circle with a meaning-specific
//  glyph inside. The hand-rolled bar built that as a ZStack of a `Circle` and
//  an `Image`, which a system tab bar can't use — it renders one template
//  image per tab, not an arbitrary view.
//
//  The `.circle` variants of the same glyphs carry that language as single
//  SF Symbols. Two departures from the mockup, both deliberate:
//
//    * `slider.horizontal.3` has no `.circle` variant (checked — it doesn't
//      exist), so Settings uses `gearshape.circle`: a gear rather than
//      sliders.
//    * The rings render *filled*, not stroked. A tab bar substitutes the
//      `.fill` variant of a symbol itself, and `.symbolVariant(.none)` does
//      not reach it — the bar is UIKit-backed and ignores it (tried; no
//      effect, so the modifier isn't left in the code pretending otherwise).
//
//  Both were worth it: the alternative was authoring a custom `.symbolset`,
//  or keeping a bar that threw away every screen's state on each switch.
//
//  The design also draws a fake home indicator bar under the tabs; that's the
//  OS's own on a real device, so it was never reproduced.
//

import SwiftUI

enum AppTab: CaseIterable, Hashable {
    case today, diary, progress, settings

    var label: String {
        switch self {
        case .today: return "Today"
        case .diary: return "Diary"
        case .progress: return "Progress"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .today: return "sunrise.circle"
        case .diary: return "list.bullet.circle"
        case .progress: return "chart.line.uptrend.xyaxis.circle"
        case .settings: return "gearshape.circle"
        }
    }
}
