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
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                Text("🏃 Exercise")
                    .appBody(13, weight: .semibold)
                    .foregroundStyle(AppColor.ink)

                if hasLogged {
                    // "30 min · -180" — the calorie figure is a deficit
                    // against the day's balance, hence the minus sign; not a
                    // literal negative number anywhere in the data.
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(Int(durationMinutes))")
                            .appBody(20, weight: .bold)
                            .foregroundStyle(AppColor.ink)
                        Text("min")
                            .appBody(13)
                            .foregroundStyle(AppColor.secondaryText)
                        Text("· -\(Int(caloriesBurned))")
                            .appBody(13)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                    .contentTransition(.numericText())
                } else {
                    Text("Log today's →")
                        .appBody(13, weight: .semibold)
                        .foregroundStyle(AppColor.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Same hit-area trick BodyCard's weight button uses: the padding
            // grows the tappable area to the card's own edges without
            // changing the laid-out spacing.
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hasLogged ? "Exercise" : "Log today's exercise")
        .accessibilityValue(
            hasLogged
                ? "\(Int(durationMinutes)) minutes, \(Int(caloriesBurned)) calories burned"
                : "Not logged"
        )
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppColor.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
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
