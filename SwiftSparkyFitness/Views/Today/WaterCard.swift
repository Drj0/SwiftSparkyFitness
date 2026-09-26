//
//  WaterCard.swift
//  SwiftSparkyFitness
//
//  Replaces Today's read-only water stub. The "−" is the mis-tap fix: it
//  removes the most recent drink rather than being a second way to type a
//  number, which is what the backend's own decrement does.
//
//  The unit and increment are the backend's, not this app's: one tap is one
//  drink, and a drink with no container configured is exactly 250 ml
//  (2000/8 in the server's upsertWaterIntake, verified live). The old card
//  divided by 240 and called the result "cups" — that figure existed
//  nowhere on the server, so a tap and the label would have disagreed.
//

import SwiftUI

struct WaterCard: View {
    @ObservedObject var viewModel: WaterViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var totalLabel: String {
        // Litres, matching the design — "1.75 / 2.5 L" rather than the raw
        // millilitre figure, which is what the number actually is server-side.
        "\(Self.liters(viewModel.totalMl)) / \(Self.liters(viewModel.goalMl)) L"
    }

    private static func liters(_ ml: Double) -> String {
        let value = ml / 1000
        // "2" not "2.0": a round number shouldn't carry a decimal the design
        // doesn't show.
        return value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    /// "ml" is read out as a letter pair; the numbers are the whole point of
    /// this card, so VoiceOver gets the unit spelled out and the percentage
    /// the progress bar communicates visually.
    private var totalAccessibilityValue: String {
        let percent = Int((viewModel.progress * 100).rounded())
        return "\(Int(viewModel.totalMl.rounded())) of \(Int(viewModel.goalMl.rounded())) millilitres, \(percent) percent"
    }

    /// No longer shown as a caption (the design keeps this card to the
    /// number, the bar and the two stepper buttons) — folded into the "+"
    /// button's own accessibility label instead, so the container/drink-size
    /// information isn't lost, only the visible line. `drinkLabel` already
    /// carries the ml figure ("250 ml each" / "Probe Bottle · 750 ml"), so
    /// it's the whole suffix — prefixing a second, separately-computed "X
    /// millilitre drink" here read as "Add a 250 millilitre drink · 250 ml
    /// each", the same number said twice.
    private var addLabel: String {
        "Add a drink — \(viewModel.drinkLabel)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("💧 Water")
                            .appBody(13, weight: .semibold)
                            .foregroundStyle(AppColor.water)
                        Spacer()
                        if viewModel.foodMl > 0 {
                            Text("incl. \(Int(viewModel.foodMl.rounded())) ml from food")
                                .appBody(11)
                                .foregroundStyle(AppColor.secondaryText)
                        }
                    }

                    // The total and the bar are one fact, not two: read
                    // separately, VoiceOver announced an unlabelled "1.75 / 2.5
                    // L" and then a progress indicator restating it with no
                    // words at all.
                    VStack(alignment: .leading, spacing: 10) {
                        Text(totalLabel)
                            .appBody(24, weight: .bold)
                            .foregroundStyle(AppColor.ink)
                            .contentTransition(.numericText())
                            .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: viewModel.totalMl)

                        progressBar
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Water")
                    .accessibilityValue(totalAccessibilityValue)
                }

                // Side by side, not stacked — a vertical column read as
                // "on top of and below each other" rather than the paired
                // stepper this is; a horizontal pair also reads as one
                // control at a glance, the way "-" and "+" normally do next
                // to each other. Centred on the card's full height by the
                // HStack above, same as before.
                HStack(spacing: 8) {
                    stepperButton(
                        systemName: "minus", label: "Remove the last drink",
                        isEnabled: viewModel.canUndo
                    ) {
                        Haptics.light()
                        Task { await viewModel.adjust(drinks: -1) }
                    }
                    stepperButton(
                        systemName: "plus", label: addLabel,
                        isEnabled: true
                    ) {
                        // Fired here rather than after the write lands: a tap
                        // has to be felt in the same frame it happens, and the
                        // round trip is 200–400 ms away.
                        Haptics.light()
                        Task { await viewModel.adjust(drinks: 1) }
                    }
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .appBody(12)
                    .foregroundStyle(AppColor.destructive)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.waterSoft)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    /// Hand-rolled rather than a `ProgressView`: the system bar ignored
    /// `.tint(AppColor.water)` and drew itself in the app's accent colour
    /// instead (caught in a render — it was yellow inside a blue card), and
    /// the `scaleEffect` needed to thicken it left a visible artifact at the
    /// midpoint. RingChart is drawn by hand for the same reason.
    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(AppColor.surface.opacity(0.6))
                Capsule()
                    .fill(AppColor.water)
                    .frame(width: max(0, geometry.size.width * viewModel.progress))
                // Past the goal, a second lap over the full bar — otherwise
                // 2 litres and 4 litres drew identically. Deeper water, not
                // red: drinking more than you planned isn't a warning.
                if viewModel.overshoot > 0 {
                    Capsule()
                        .fill(AppColor.ink.opacity(0.35))
                        .frame(width: max(0, geometry.size.width * viewModel.overshoot))
                }
            }
        }
        .frame(height: 6)
        // The fill used to snap to its new width the instant the server
        // answered; it now travels with the optimistic total.
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.85), value: viewModel.progress)
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.85), value: viewModel.overshoot)
    }

    /// Both buttons share one look now — matched size, filled blue circle,
    /// white icon — rather than "+" being prominent and "-" a quieter
    /// outline; the two are equally common taps (undo a drink, add one), so
    /// nothing here should read as more or less important than the other.
    private func stepperButton(
        systemName: String, label: String, isEnabled: Bool, action: @escaping () -> Void
    ) -> some View {
        // Smaller than the old "+" (36pt), which was the larger of the two.
        let diameter: CGFloat = 32
        // Under the 44pt minimum touch target, so pad a tappable area back
        // out to it — horizontally, since side by side it's the row's
        // *width* that would otherwise overshoot the declared 8pt spacing,
        // not its height. Same trick this app uses everywhere a visual size
        // and a touch target differ (see the meal-row "+" in TodayView).
        let growth = (44 - diameter) / 2
        return Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .background(AppColor.water, in: Circle())
                .opacity(isEnabled ? 1 : 0.5)
                // The visual circle is the design's size; the tappable area
                // is padded out to the 44pt minimum a thumb needs.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .padding(.horizontal, -growth)
        }
        .buttonStyle(.pressableCompact)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }
}

/// Custom-amount entry. Deliberately a small sheet rather than an inline
/// field: the card's job is one-tap logging, and a keyboard opening inside
/// it would push the day's other cards around.
struct LogWaterAmountView: View {
    @ObservedObject var viewModel: WaterViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var amountText = ""
    @State private var validationError: String?

    private var parsedAmount: Double? {
        Double(amountText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: "Add Water",
                onCancel: { dismiss() },
                action: SheetAction("Add", isBusy: viewModel.isBusy) {
                    Task { await add() }
                }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let bannerMessage = viewModel.errorMessage {
                        ErrorBanner(message: bannerMessage)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("AMOUNT (ML)")
                            .appBody(12, weight: .semibold)
                            .foregroundStyle(validationError == nil ? AppColor.secondaryText : AppColor.destructive)
                        HStack {
                            TextField("e.g. 300", text: $amountText)
                                .appBody(15)
                                .foregroundStyle(AppColor.ink)
                                .keyboardType(.numberPad)
                            Text("ml")
                                .appBody(13)
                                .foregroundStyle(AppColor.secondaryText)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(AppColor.inputBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(validationError == nil ? .clear : AppColor.destructive, lineWidth: 2)
                        )
                        if let validationError {
                            Text(validationError).appBody(12).foregroundStyle(AppColor.destructive)
                        }
                    }

                    Text("Logged as a single entry you can delete from the Diary.")
                        .appBody(12)
                        .foregroundStyle(AppColor.secondaryText)
                }
                .padding(18)
            }
        }
        .background(AppColor.surface)
        .onAppear { viewModel.clearError() }
    }

    private func add() async {
        guard let amount = parsedAmount, amount > 0 else {
            validationError = "How much did you drink?"
            Haptics.error()
            return
        }
        // numeric(10,3) tops out well above any real drink; this catches a
        // slipped decimal point rather than a database limit.
        guard amount <= 5000 else {
            validationError = "That looks too high"
            Haptics.error()
            return
        }
        validationError = nil
        if await viewModel.logExactAmount(amount) {
            dismiss()
        }
    }
}
