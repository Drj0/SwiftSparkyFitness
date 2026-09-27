//
//  ExerciseTodayCard.swift
//  SwiftSparkyFitness
//
//  Today's exercise total, sitting beside BodyCard the same way the design
//  pairs a Weight card and an Exercise card under the Water card. Mirrors
//  BodyCard's shape deliberately (label row, then the day's headline number)
//  so the two read as one family rather than two different card idioms.
//

import SwiftUI

struct ExerciseTodayCard: View {
    let durationMinutes: Double
    let caloriesBurned: Double
    let hasLogged: Bool
    /// False while Today is showing a past day from the week strip.
    var isToday = true
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            TodayStatTile(
                title: "🏃 Exercise",
                value: hasLogged ? "\(Int(durationMinutes))" : nil,
                unit: "min",
                caption: hasLogged ? "−\(Int(caloriesBurned)) kcal burned" : (isToday ? "Log today's →" : "Log →"),
                captionIsAction: !hasLogged
            )
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hasLogged ? "Exercise" : isToday ? "Log today's exercise" : "Log exercise")
        .accessibilityValue(
            hasLogged
                ? "\(Int(durationMinutes)) minutes, \(Int(caloriesBurned)) calories burned"
                : "Not logged"
        )
    }
}

#Preview {
    HStack(spacing: 12) {
        ExerciseTodayCard(durationMinutes: 30, caloriesBurned: 180, hasLogged: true) {}
        ExerciseTodayCard(durationMinutes: 0, caloriesBurned: 0, hasLogged: false) {}
    }
    .padding()
    .background(AppColor.background)
}

/// The shared shell of Today's half-width Weight and Exercise cards. Every
/// state has the same three rows — title, value ("—" when nothing's logged),
/// caption — so the two cards match each other and don't change height when
/// something gets logged. The card fills whatever height its row gives it,
/// which is what keeps the pair level at large text sizes.
struct TodayStatTile: View {
    let title: String
    /// nil renders a placeholder dash in the value's own style.
    let value: String?
    var unit = ""
    let caption: String
    /// "Log →" reads as an action (accent); everything else is a quiet fact.
    var captionIsAction = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Capped: half-width beside a sibling, the title wraps mid-word
            // ("Weig" / "ht") at accessibility sizes otherwise.
            Text(title)
                .appBody(13, weight: .semibold)
                .foregroundStyle(AppColor.ink)
                .dynamicTypeSize(...DynamicTypeSize.xLarge)
                .padding(.bottom, 6)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value ?? "—")
                    .appBody(22, weight: .bold)
                    .foregroundStyle(value == nil ? AppColor.placeholder : AppColor.ink)
                if value != nil, !unit.isEmpty {
                    Text(unit)
                        .appBody(13)
                        .foregroundStyle(AppColor.secondaryText)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .contentTransition(.numericText())

            Text(caption)
                .appBody(12, weight: captionIsAction ? .semibold : .regular)
                .foregroundStyle(captionIsAction ? AppColor.accent : AppColor.secondaryText)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .background(AppColor.surface)
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppColor.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .contentShape(Rectangle())
    }
}
