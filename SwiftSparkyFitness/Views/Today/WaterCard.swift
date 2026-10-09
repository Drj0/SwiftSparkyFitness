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
    /// The custom-amount sheet, reached by holding "+".
    @State private var isLoggingAmount = false

    /// Same shell as Today's Weight and Exercise tiles (TodayStatTile) so
    /// the three read as one family; blue is only water's accent — the bar
    /// and the "+" glyph — the way the macro card colours only its bars. A
    /// whole blue card was the one tinted card on the screen.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                CardTitle("Water", symbol: "drop.fill", tint: AppColor.water)
                Spacer()
                if viewModel.foodMl > 0 {
                    Text("incl. \(Int(viewModel.foodMl.rounded())) ml from food")
                        .appBody(11)
                        .foregroundStyle(AppColor.secondaryText)
                }
            }
            .padding(.bottom, 6)

            HStack(alignment: .center, spacing: 12) {
                // The total, the goal and what's left are one fact: read
                // separately, VoiceOver announced an unlabelled "750 ml"
                // and then restated it.
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(Self.amount(viewModel.totalMl).value)
                            .appBody(22, weight: .bold)
                            .foregroundStyle(viewModel.totalMl > 0 ? AppColor.ink : AppColor.placeholder)
                            .contentTransition(.numericText())
                            .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: viewModel.totalMl)
                        Text("\(Self.amount(viewModel.totalMl).unit) of \(Self.liters(viewModel.goalMl))")
                            .appBody(13)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                    caption
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Water")
                .accessibilityValue(totalAccessibilityValue)

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    removeButton
                    addButton
                }
            }

            progressBar
                .padding(.top, 12)
                .accessibilityHidden(true)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .appBody(12)
                    .foregroundStyle(AppColor.destructive)
                    .padding(.top, 8)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppColor.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        // A quiet moment for the goal, felt once on the way over it.
        .sensoryFeedback(trigger: reachedGoal) { old, new in !old && new ? .success : nil }
        .sheet(isPresented: $isLoggingAmount) {
            LogWaterAmountView(viewModel: viewModel)
                .fittedDetent()
                .presentationDragIndicator(.visible)
        }
    }

    private var reachedGoal: Bool { viewModel.goalMl > 0 && viewModel.totalMl >= viewModel.goalMl }

    /// What's left leads — it's what prompts the next glass — followed by
    /// what one tap adds, which the "+" itself can't say.
    private var caption: some View {
        // One Text, so large sizes wrap onto a second line (as the Weight and
        // Exercise tiles' captions do) instead of truncating the tap size.
        let lead: Text = reachedGoal
            ? Text(Image(systemName: "checkmark.circle.fill")).foregroundStyle(AppColor.water)
                + Text(" Goal reached").foregroundStyle(AppColor.ink)
            : Text("\(Self.liters(viewModel.goalMl - viewModel.totalMl)) to go")
        return (lead + Text(" · \(Int(viewModel.mlPerDrink.rounded()))\u{00A0}ml a\u{00A0}tap"))
            .appBody(12)
            .foregroundStyle(AppColor.secondaryText)
            .lineLimit(2)
    }

    /// "750 ml" under a litre, "1.25 L" from there: small amounts read
    /// naturally in millilitres, and "0.50 L" mixed precision with the goal.
    private static func amount(_ ml: Double) -> (value: String, unit: String) {
        ml < 1000 ? ("\(Int(ml.rounded()))", "ml") : (number(ml / 1000), "L")
    }

    private static func liters(_ ml: Double) -> String {
        ml < 1000 ? "\(Int(max(0, ml).rounded()))\u{00A0}ml" : "\(number(ml / 1000))\u{00A0}L"
    }

    /// "2" not "2.0", "1.25" not "1.250".
    private static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    /// "ml" is read out as a letter pair; the numbers are the whole point of
    /// this card, so VoiceOver gets the unit spelled out and the percentage
    /// the progress bar communicates visually.
    private var totalAccessibilityValue: String {
        let percent = Int((viewModel.progress * 100).rounded())
        return "\(Int(viewModel.totalMl.rounded())) of \(Int(viewModel.goalMl.rounded())) millilitres, \(percent) percent"
    }

    /// Hand-rolled rather than a `ProgressView`: the system bar ignored
    /// `.tint(AppColor.water)` and drew itself in the app's accent colour.
    /// Track and height match the macro card's bars.
    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(AppColor.ringTrack)
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
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.85), value: viewModel.progress)
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.85), value: viewModel.overshoot)
    }

    /// Undo is the rare tap, so it's the quiet one: grey on the input
    /// tone, where "+" wears water's tint like a meal row's "+" wears pink.
    private var removeButton: some View {
        Button {
            Haptics.light()
            Task { await viewModel.adjust(drinks: -1) }
        } label: {
            circle("minus", diameter: 32, fill: AppColor.inputBackground, glyph: AppColor.secondaryText)
                .opacity(viewModel.canUndo ? 1 : 0.5)
        }
        .buttonStyle(.pressableCompact)
        .disabled(!viewModel.canUndo)
        .accessibilityLabel("Remove the last drink")
    }

    /// Tap adds one drink; hold for other amounts. The menu keeps the
    /// one-tap path untouched while making a bottle or a can loggable.
    private var addButton: some View {
        Menu {
            Button("\(Int((viewModel.mlPerDrink * 2).rounded())) ml · 2 drinks", systemImage: "drop.fill") {
                Haptics.light()
                Task { await viewModel.adjust(drinks: 2) }
            }
            Button("Custom amount…", systemImage: "pencil") { isLoggingAmount = true }
        } label: {
            circle("plus", diameter: 36, fill: AppColor.waterSoft, glyph: AppColor.water)
        } primaryAction: {
            // Fired here rather than after the write lands: a tap has to be
            // felt in the same frame it happens.
            Haptics.light()
            Task { await viewModel.adjust(drinks: 1) }
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("Add a drink — \(viewModel.drinkLabel)")
        .accessibilityHint("Hold for other amounts")
    }

    /// The visual circle is the design's size; the tappable area is padded
    /// out to the 44pt minimum a thumb needs, horizontally trimmed back so
    /// the pair keeps its 8pt spacing.
    private func circle(_ systemName: String, diameter: CGFloat, fill: Color, glyph: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(glyph)
            .frame(width: diameter, height: diameter)
            .background(fill, in: Circle())
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .padding(.horizontal, -(44 - diameter) / 2)
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
    @FocusState private var amountFocused: Bool

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
            .sheetHeightPart()

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
                                .focused($amountFocused)
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
                .sheetHeightPart()
            }
        }
        .background(AppColor.surface)
        .onAppear { viewModel.clearError() }
        // Opened from "Custom amount…" to type a number; no reason to make
        // that a second tap.
        .task { amountFocused = true }
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
