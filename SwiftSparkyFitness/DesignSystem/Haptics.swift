//
//  Haptics.swift
//  SwiftSparkyFitness
//
//  Thin wrappers over UIKit's feedback generators so call sites read as
//  intent (`.selection()`, `.success()`) instead of repeating
//  `UIImpactFeedbackGenerator(style:).impactOccurred()` everywhere.
//

import UIKit

enum Haptics {
    /// Value-changing controls this app hand-rolls instead of using a real
    /// UITabBar/UISegmentedControl (which would fire this for free): the
    /// custom tab bar, meal/intensity chips, date paging.
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// A small increment "landing" — the food-quantity stepper.
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// About to do something destructive (swipe-to-delete).
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
