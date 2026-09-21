//
//  PressableStyle.swift
//  SwiftSparkyFitness
//
//  Press feedback for the app's hand-rolled controls.
//
//  Most custom buttons here used `.buttonStyle(.plain)`, which removes *all*
//  press response — so every tap had to wait on a network round trip before
//  the UI admitted it had happened. This gives the shortest possible feedback
//  loop: the control acknowledges contact in under a frame, independent of
//  anything asynchronous.
//
//  `.plain` is still correct for a control whose own body already renders a
//  pressed state; use this everywhere else instead of `.plain`.
//

import SwiftUI

struct PressableStyle: ButtonStyle {
    /// Smaller controls can take a deeper squash before it looks wrong; a
    /// full-width button moving 4% reads as a glitch, so it gets less.
    var scale: CGFloat = 0.96
    var dimsOnPress: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? scale : 1))
            .opacity(configuration.isPressed && dimsOnPress ? 0.72 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    /// Row-sized and card-sized controls.
    static var pressable: PressableStyle { PressableStyle() }
    /// Large full-width buttons — less travel, or it reads as a wobble.
    static var pressableLarge: PressableStyle { PressableStyle(scale: 0.985) }
    /// Small circular targets (the FAB, steppers) — they can take more.
    static var pressableCompact: PressableStyle { PressableStyle(scale: 0.92) }
}
