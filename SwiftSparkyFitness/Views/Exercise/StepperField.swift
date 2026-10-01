//
//  StepperField.swift
//  SwiftSparkyFitness
//
//  A number you can type or nudge: − and + either side of an editable
//  field, the way Log Weight already works. Most of a set's numbers change
//  by one rep or one plate from the set before, so a tap beats the number
//  pad — and the field still takes typing for a bigger jump.
//

import SwiftUI

struct StepperField: View {
    /// What the number is, for VoiceOver ("Reps, set 2").
    let label: String
    @Binding var text: String
    var placeholder = ""
    var unit: String?
    var keyboardType: UIKeyboardType = .numberPad
    /// "1 rep", "2.5 kg" — read out on the buttons.
    let stepLabel: String
    let onStep: (Double) -> Void

    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 46

    var body: some View {
        HStack(spacing: 0) {
            stepButton(systemImage: "minus", direction: -1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                TextField(placeholder, text: $text)
                    .appBody(17, weight: .semibold)
                    .foregroundStyle(AppColor.ink)
                    .multilineTextAlignment(.center)
                    .keyboardType(keyboardType)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityLabel(label)
                if let unit {
                    Text(unit)
                        .appBody(12)
                        .foregroundStyle(AppColor.secondaryText)
                        .fixedSize()
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
            stepButton(systemImage: "plus", direction: 1)
        }
        .frame(minHeight: height)
        .background(AppColor.inputBackground, in: RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
    }

    private func stepButton(systemImage: String, direction: Double) -> some View {
        Button {
            Haptics.light()
            onStep(direction)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AppColor.accent)
                .frame(width: 38)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressableCompact)
        .accessibilityLabel("\(direction > 0 ? "Increase" : "Decrease") \(label.lowercased()) by \(stepLabel)")
    }
}

/// A row of preset values under a field — "15 30 45 60 min" — one tap to
/// the usual answer.
struct PresetChips: View {
    let values: [Int]
    let unitLabel: String
    let spokenUnit: String
    let selected: Int?
    let onPick: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(values, id: \.self) { value in
                let isSelected = value == selected
                Button {
                    guard !isSelected else { return }
                    Haptics.selection()
                    onPick(value)
                } label: {
                    Text("\(value)")
                        .appBody(13, weight: .semibold)
                        .foregroundStyle(isSelected ? .white : AppColor.secondaryText)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(isSelected ? AppColor.accent : AppColor.inputBackground, in: Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("\(value) \(spokenUnit)")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
            Text(unitLabel)
                .appBody(12)
                .foregroundStyle(AppColor.secondaryText)
                .fixedSize()
                .accessibilityHidden(true)
        }
    }
}
