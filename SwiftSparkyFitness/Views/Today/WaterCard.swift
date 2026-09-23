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
    let onEnterAmount: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var totalLabel: String {
        "\(Int(viewModel.totalMl.rounded())) / \(Int(viewModel.goalMl.rounded())) ml"
    }

    /// "ml" is read out as a letter pair; the numbers are the whole point of
    /// this card, so VoiceOver gets the unit spelled out and the percentage
    /// the progress bar communicates visually.
    private var totalAccessibilityValue: String {
        let percent = Int((viewModel.progress * 100).rounded())
        return "\(Int(viewModel.totalMl.rounded())) of \(Int(viewModel.goalMl.rounded())) millilitres, \(percent) percent"
    }

    private var perDrinkLabel: String {
        let drinks = viewModel.wholeDrinks
        let noun = drinks == 1 ? "glass" : "glasses"
        // The second half names the container when one is set, so a tap that
        // logs 750 ml doesn't still claim to be worth 250.
        return "\(drinks) \(noun) · \(viewModel.drinkLabel)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("💧 Water")
                    .appBody(12, weight: .semibold)
                    .foregroundStyle(AppColor.water)
                Spacer()
                if viewModel.foodMl > 0 {
                    Text("incl. \(Int(viewModel.foodMl.rounded())) ml from food")
                        .appBody(11)
                        .foregroundStyle(AppColor.secondaryText)
                }
            }

            // The total and the bar are one fact, not two: read separately,
            // VoiceOver announced an unlabelled "1250 / 2000 ml" and then a
            // progress indicator restating it with no words at all.
            VStack(alignment: .leading, spacing: 10) {
                Text(totalLabel)
                    .appBody(20, weight: .bold)
                    .foregroundStyle(AppColor.ink)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: viewModel.totalMl)

                progressBar
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Water")
            .accessibilityValue(totalAccessibilityValue)

            HStack(spacing: 12) {
                stepperButton(systemName: "minus", label: "Remove the last drink", isEnabled: viewModel.canUndo) {
                    // Fired here rather than after the write lands: a tap has
                    // to be felt in the same frame it happens, and the round
                    // trip is 200–400 ms away.
                    Haptics.light()
                    Task { await viewModel.adjust(drinks: -1) }
                }

                Text(perDrinkLabel)
                    .appBody(12)
                    .foregroundStyle(AppColor.secondaryText)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)

                stepperButton(systemName: "plus", label: "Add a \(Int(viewModel.mlPerDrink)) millilitre drink", isEnabled: true) {
                    Haptics.light()
                    Task { await viewModel.adjust(drinks: 1) }
                }
            }
            // The 44pt touch targets are 6pt taller than the 38pt circles
            // they wrap; handing that growth back keeps the card the height
            // it was designed at.
            .padding(.vertical, -3)

            Button(action: onEnterAmount) {
                Text("Enter amount…")
                    .appBody(13, weight: .semibold)
                    .foregroundStyle(AppColor.water)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(AppColor.surface.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
            }
            .buttonStyle(.pressable)

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
            }
        }
        .frame(height: 6)
        // The fill used to snap to its new width the instant the server
        // answered; it now travels with the optimistic total.
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.85), value: viewModel.progress)
    }

    private func stepperButton(systemName: String, label: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(isEnabled ? AppColor.water : AppColor.placeholder)
                .frame(width: 38, height: 38)
                .background(AppColor.surface, in: Circle())
                // 38pt circle, 44pt target — the visual size is the design's,
                // the tappable size is the minimum a thumb can hit.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .padding(.horizontal, -3)
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
            HStack {
                Button("Cancel") { dismiss() }.foregroundStyle(AppColor.secondaryText)
                Spacer()
                Text("Add Water").appDisplay(18).foregroundStyle(AppColor.ink)
                Spacer()
                Button("Add") { Task { await add() } }
                    .foregroundStyle(AppColor.accent)
                    .fontWeight(.semibold)
                    .disabled(viewModel.isBusy)
            }
            .appBody(15)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .overlay(Rectangle().fill(AppColor.hairline).frame(height: 1), alignment: .bottom)

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
