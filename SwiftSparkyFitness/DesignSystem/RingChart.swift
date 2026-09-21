//
//  RingChart.swift
//  SwiftSparkyFitness
//
//  The Today screen's triple concentric ring (calories/active energy/water).
//  Populated and empty-goal states share this exact view — "empty" is just
//  three progress values of 0, so there's no separate empty-state variant of
//  the ring itself, only of the content drawn around it.
//
//  ponytail: skipped the design's "+120 kcal earned" tick-mark + callout that
//  marks where the original goal edge was before exercise extended the ring.
//  Add it if/when the app actually earns kcal back for logged exercise in a
//  way users need explained; the plain extended arc already reads correctly
//  without it.
//

import SwiftUI

struct RingLayer {
    let progress: Double
    let color: Color
}

struct RingChart<Center: View>: View {
    let layers: [RingLayer]
    var diameter: CGFloat = 220
    var trackWidth: CGFloat = 14
    var gap: CGFloat = 8
    let center: Center
    /// One spoken summary of all three arcs. The rings convey their values
    /// through arc length and colour alone, so without this VoiceOver got
    /// only the loose texts in the middle ("978", "kcal left") and nothing
    /// at all about active energy or water — two thirds of the dashboard.
    var accessibilityDescription: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the draw-on animation: arcs are trimmed to 0 for the first
    /// frame, then animate out to their real values once the view appears.
    @State private var hasAppeared = false

    init(layers: [RingLayer], diameter: CGFloat = 220, trackWidth: CGFloat = 14, gap: CGFloat = 8,
         accessibilityDescription: String? = nil, @ViewBuilder center: () -> Center) {
        self.layers = layers
        self.diameter = diameter
        self.trackWidth = trackWidth
        self.gap = gap
        self.accessibilityDescription = accessibilityDescription
        self.center = center()
    }

    var body: some View {
        ZStack {
            ForEach(layers.indices, id: \.self) { index in
                let radius = diameter / 2 - CGFloat(index) * (trackWidth + gap)
                ring(radius: radius, layer: layers[index], index: index)
            }
            center
        }
        .frame(width: diameter, height: diameter)
        .onAppear {
            guard !hasAppeared else { return }
            if reduceMotion {
                hasAppeared = true
            } else {
                withAnimation(.easeOut(duration: 0.85)) { hasAppeared = true }
            }
        }
        .accessibilityElement(children: accessibilityDescription == nil ? .contain : .ignore)
        .accessibilityLabel(accessibilityDescription == nil ? "" : "Daily progress")
        .accessibilityValue(accessibilityDescription ?? "")
    }

    init(layers: [RingLayer], diameter: CGFloat = 220, trackWidth: CGFloat = 14, gap: CGFloat = 8,
         accessibilityDescription: String? = nil) where Center == EmptyView {
        self.init(layers: layers, diameter: diameter, trackWidth: trackWidth, gap: gap,
                  accessibilityDescription: accessibilityDescription) { EmptyView() }
    }

    private func ring(radius: CGFloat, layer: RingLayer, index: Int) -> some View {
        // Clamped for the base arc; the overshoot past 1.0 is drawn as its own
        // lap on top, so going over a goal no longer looks like hitting it.
        let clamped = max(0, min(1, layer.progress))
        let overshoot = max(0, min(1, layer.progress - 1))
        return ZStack {
            Circle()
                .stroke(AppColor.ringTrack, style: StrokeStyle(lineWidth: trackWidth))
            Circle()
                .trim(from: 0, to: hasAppeared ? clamped : 0)
                .stroke(layer.color, style: StrokeStyle(lineWidth: trackWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if overshoot > 0 {
                Circle()
                    .trim(from: 0, to: hasAppeared ? overshoot : 0)
                    .stroke(AppColor.destructive, style: StrokeStyle(lineWidth: trackWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        // Each ring eases to its new value on change, slightly staggered so
        // the three read as one coordinated move rather than a single jump.
        .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.85)
            .delay(Double(index) * 0.06), value: layer.progress)
        .frame(width: radius * 2, height: radius * 2)
    }
}

/// The dashed single-ring "goal not set" state — visually distinct from an
/// empty-but-configured ring so it reads as "unconfigured," not "no data yet."
struct GoalNotSetRing: View {
    var diameter: CGFloat = 190

    var body: some View {
        ZStack {
            Circle()
                .stroke(AppColor.ringTrack, style: StrokeStyle(lineWidth: 13, dash: [5, 7]))
            VStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AppColor.accent)
                Text("Set a daily\ngoal to start")
                    .appBody(14)
                    .foregroundStyle(AppColor.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

#Preview("Populated") {
    RingChart(layers: [
        RingLayer(progress: 0.65, color: AppColor.accent),
        RingLayer(progress: 0.3, color: AppColor.energy),
        RingLayer(progress: 0.6, color: AppColor.water),
    ])
}

#Preview("Goal not set") {
    GoalNotSetRing()
}
