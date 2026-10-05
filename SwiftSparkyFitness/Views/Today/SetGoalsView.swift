//
//  SetGoalsView.swift
//  SwiftSparkyFitness
//
//  Sets the daily calorie / macro / water goals. Pushed from Settings, and
//  presented from Today's goal-not-set card.
//
//  The sheet cannot save until its load succeeds, and that's deliberate
//  rather than defensive: the goal write replaces the entire row, so building
//  one without the server's current values silently zeroes every column this
//  app doesn't model. See NutritionGoals and GoalsViewModel.
//
//  A PAGE, AND NO KEYBOARD
//  -----------------------
//  This was five text fields in a modal sheet. Both halves were wrong:
//
//    * **The sheet.** Goals aren't a task you interrupt yourself with, they're
//      a place you go — and from Settings it now pushes, with a title and a
//      back button, like every other destination there. Today still presents
//      it, because from a card that says "no goal yet" it genuinely *is* an
//      interruption; the same view covers both, adding a Cancel only when it
//      is the thing being presented.
//    * **The keyboard.** Typing "2200" into a box is the slowest, least
//      confident way to answer "what should my calories be", and it puts a
//      keyboard over the numbers you're trying to reason about. The calorie
//      goal is a wheel, the macros and water are steppers, and nothing here
//      raises a keyboard at all.
//
//  Macros stay in GRAMS, which is what the column stores, but the form shows
//  each one's share of the day as a percentage and totals them against the
//  calorie goal. Setting 200 g of protein against 1,500 kcal is the easiest
//  mistake to make on this screen and was previously invisible. The quick
//  splits go the other way — a percentage split most people can name, turned
//  into grams — which is how MyFitnessPal and every macro calculator frames
//  it, without giving up the exact gram values the server round-trips.
//

import SwiftUI

struct SetGoalsView: View {
    @StateObject private var viewModel: GoalsViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingDiscard = false
    @State private var isRecalculating = false

    /// Set by the sheet presentation (Today) and not by the push (Settings):
    /// a pushed screen already has a back button, and a second way out
    /// labelled "Cancel" beside it is noise.
    ///
    /// Passed in rather than read from `\.isPresented`, which was tried and
    /// is wrong for this — it reports true for anything `dismiss()` can
    /// close, a pushed view included, so the pushed page drew a back chevron
    /// and a Cancel side by side.
    private let showsCancel: Bool
    private let onSaved: () -> Void

    init(date: Date = Date(), showsCancel: Bool = false, onSaved: @escaping () -> Void = {}) {
        _viewModel = StateObject(wrappedValue: GoalsViewModel(date: date))
        self.showsCancel = showsCancel
        self.onSaved = onSaved
    }

    /// 800–6,000 in tens, plus whatever is already stored if it falls between
    /// two stops — a goal set to 2,187 from the web client has to be
    /// selectable, or the wheel would show a blank row and then quietly round
    /// it on the next save.
    private var calorieOptions: [Int] {
        let stops = Array(stride(from: 800, through: 6000, by: 10))
        let current = Int(viewModel.value(for: .calories, fallback: GoalsViewModel.suggestedCalories).rounded())
        guard !stops.contains(current), current > 0 else { return stops }
        return (stops + [current]).sorted()
    }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.loaded == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppColor.background)
            } else if viewModel.loadFailed {
                loadFailedState
            } else {
                form
            }
        }
        .navigationTitle("Goals")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(!showsCancel && viewModel.isDirty)
        .toolbar {
            // Pushed from Settings the system back button would drop edits
            // silently, so while there are any it's swapped for one that asks.
            if !showsCancel && viewModel.isDirty {
                ToolbarItem(placement: .topBarLeading) {
                    Button { confirmingDiscard = true } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                }
            }
            if showsCancel {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { if viewModel.isDirty { confirmingDiscard = true } else { dismiss() } }
                        .tint(AppColor.secondaryText)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        if await viewModel.save() {
                            onSaved()
                            dismiss()
                        }
                    }
                } label: {
                    if viewModel.isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save").appBody(15, weight: .semibold)
                    }
                }
                .disabled(!viewModel.canSave)
                .tint(AppColor.accent)
            }
        }
        .task { await viewModel.load() }
        .discardGuard(isDirty: viewModel.isDirty, isPresented: $confirmingDiscard) { dismiss() }
        // Saves the goals itself, so this form reloads after: a Save from
        // the stale copy would put the old numbers back.
        .fullScreenCover(isPresented: $isRecalculating) {
            OnboardingView(account: ServerSync.shared.account, isRerun: true) {
                isRecalculating = false
                Task { await viewModel.load() }
                onSaved()
            }
        }
    }

    private var form: some View {
        List {
            if let bannerMessage = viewModel.bannerMessage {
                Section {
                    ErrorBanner(message: bannerMessage)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            calorieSection
            macroSection
            waterSection
            recalculateSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppColor.background)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: viewModel.bannerMessage)
    }

    // MARK: - Calories

    private var calorieSection: some View {
        Section {
            // The wheel is the section, not a row that opens one: this single
            // number is what the whole screen is for, and hiding it behind a
            // disclosure would be ceremony in front of the main event.
            Picker("Daily calories", selection: calorieSelection) {
                ForEach(calorieOptions, id: \.self) { value in
                    Text("\(value.formatted()) kcal")
                        .appBody(17, weight: .semibold)
                        .tag(value)
                }
            }
            .pickerStyle(.wheel)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Daily calorie goal")
            .accessibilityValue("\(Int(viewModel.value(for: .calories))) kilocalories")
        } header: {
            header("DAILY CALORIES")
        } footer: {
            footnote(
                (viewModel.loaded?.isSet ?? true)
                    ? "Drives the main ring on Today."
                    : "Starting from a typical 2,000 kcal — spin to yours. Nothing is saved until you tap Save."
            )
        }
        .listRowBackground(AppColor.surface)
    }

    /// The wheel writes through to the same string the save path reads, and
    /// ticks as it passes each stop — the one feedback a wheel is expected to
    /// give and the only way this form confirms a change at all now that
    /// there's no keyboard.
    private var calorieSelection: Binding<Int> {
        Binding(
            get: { Int(viewModel.value(for: .calories, fallback: GoalsViewModel.suggestedCalories).rounded()) },
            set: { newValue in
                guard newValue != Int(viewModel.value(for: .calories).rounded()) else { return }
                viewModel.setValue(Double(newValue), for: .calories)
                Haptics.selection()
            }
        )
    }

    // MARK: - Macros

    private var macroSection: some View {
        Section {
            macroRow(.protein)
            macroRow(.carbs)
            macroRow(.fat)
            macroTotal
            splitRow
        } header: {
            header("MACROS")
        } footer: {
            footnote("Optional — leave one at zero and its ring just won't show a target.")
        }
        .listRowBackground(AppColor.surface)
    }

    private func macroRow(_ field: GoalsViewModel.Field) -> some View {
        let grams = viewModel.value(for: field)
        let calories = grams * GoalsViewModel.caloriesPerGram(field)
        let goal = viewModel.value(for: .calories)
        let share = goal > 0 ? calories / goal * 100 : 0

        return Stepper(
            value: steppedBinding(for: field, by: 5, maximum: field.maximum),
            in: 0...field.maximum,
            step: 5
        ) {
            HStack(spacing: 8) {
                Text(field.title)
                    .appBody(15, weight: .semibold)
                    .foregroundStyle(AppColor.ink)
                Spacer(minLength: 8)
                Text(grams > 0 ? "\(Int(grams)) g" : "Not set")
                    .appBody(15, weight: .semibold)
                    .foregroundStyle(grams > 0 ? AppColor.ink : AppColor.placeholder)
                // The share of the day, which is the number people actually
                // reason about and the one this form used to make invisible.
                if grams > 0 && goal > 0 {
                    Text("\(Int(share.rounded()))%")
                        .appBody(12, weight: .semibold)
                        .foregroundStyle(AppColor.secondaryText)
                        .frame(minWidth: 34, alignment: .trailing)
                }
            }
        }
        .frame(minHeight: 44)
        .accessibilityValue(
            grams > 0
                ? "\(Int(grams)) grams, \(Int(share.rounded())) percent of your calories"
                : "Not set"
        )
    }

    /// Steppers fire no haptic of their own in SwiftUI, and a control with a
    /// repeat-on-hold needs one — without it a long press moves a number with
    /// no sense of how fast.
    private func steppedBinding(
        for field: GoalsViewModel.Field,
        by step: Double,
        maximum: Double
    ) -> Binding<Double> {
        Binding(
            get: { viewModel.value(for: field) },
            set: { newValue in
                let clamped = min(max(0, newValue), maximum)
                guard clamped != viewModel.value(for: field) else { return }
                viewModel.setValue(clamped, for: field)
                Haptics.light()
            }
        )
    }

    /// Macros that don't add up to the calorie goal aren't an error — plenty
    /// of people track protein alone — so this states the gap rather than
    /// refusing to save. It flags only a target that genuinely can't be met.
    ///
    /// The 2% tolerance is not slack for its own sake: grams are whole
    /// numbers and a gram of fat is 9 kcal, so an exactly-balanced split can
    /// land a few kcal either side of the goal. Flagging that would have
    /// meant every preset marking itself wrong the moment you tapped it.
    ///
    /// It says "over" as well as turning red, because a colour alone isn't a
    /// message to anyone who can't see this particular one.
    @ViewBuilder
    private var macroTotal: some View {
        let goal = viewModel.value(for: .calories)
        let fromMacros = viewModel.macroCalories
        let isOver = fromMacros > goal * 1.02

        if fromMacros > 0 && goal > 0 {
            HStack {
                Text("From macros")
                    .appBody(13)
                    .foregroundStyle(AppColor.secondaryText)
                Spacer(minLength: 8)
                Text("\(Int(fromMacros.rounded())) of \(Int(goal)) kcal\(isOver ? " — over" : "")")
                    .appBody(13, weight: .semibold)
                    .foregroundStyle(isOver ? AppColor.destructive : AppColor.secondaryText)
            }
            .frame(minHeight: 32)
            .accessibilityElement(children: .combine)
        }
    }

    /// The three splits people actually name. Grams remain the stored value;
    /// this is only a faster way to arrive at them.
    private var splitRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("QUICK SPLIT")
                .appBody(11, weight: .semibold)
                .foregroundStyle(AppColor.placeholder)

            HStack(spacing: 8) {
                splitButton("Balanced", "30/40/30", protein: 30, carbs: 40, fat: 30)
                splitButton("Low carb", "35/25/40", protein: 35, carbs: 25, fat: 40)
                splitButton("High protein", "40/30/30", protein: 40, carbs: 30, fat: 30)
            }
        }
        .padding(.vertical, 4)
    }

    private func splitButton(
        _ title: String,
        _ ratio: String,
        protein: Double,
        carbs: Double,
        fat: Double
    ) -> some View {
        Button {
            viewModel.applySplit(protein: protein, carbs: carbs, fat: fat)
            Haptics.success()
        } label: {
            VStack(spacing: 2) {
                Text(title)
                    .appBody(13, weight: .semibold)
                    .foregroundStyle(AppColor.accent)
                Text(ratio)
                    .appBody(11)
                    .foregroundStyle(AppColor.placeholder)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(AppColor.accentSoft, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("\(title) split, \(ratio) protein carbs fat")
    }

    // MARK: - Water

    private var waterSection: some View {
        Section {
            let ml = viewModel.value(for: .water)
            Stepper(
                value: steppedBinding(for: .water, by: 250, maximum: GoalsViewModel.Field.water.maximum),
                in: 0...GoalsViewModel.Field.water.maximum,
                step: 250
            ) {
                HStack {
                    Text("Daily water")
                        .appBody(15, weight: .semibold)
                        .foregroundStyle(AppColor.ink)
                    Spacer(minLength: 8)
                    Text(ml > 0 ? "\(Int(ml)) ml" : "Not set")
                        .appBody(15, weight: .semibold)
                        .foregroundStyle(ml > 0 ? AppColor.ink : AppColor.placeholder)
                }
            }
            .frame(minHeight: 44)
        } header: {
            header("WATER")
        } footer: {
            // The column is water_goal_ml whatever the display preference
            // says, so this one is always millilitres. Saying so beats a
            // number that silently means something else.
            footnote("Always in millilitres — the Units screen changes how water is shown, not how it's stored.")
        }
        .listRowBackground(AppColor.surface)
    }

    // MARK: - Recalculate

    /// Last, under the numbers it would replace: lived in Settings, a row
    /// away from the goals it rewrites.
    private var recalculateSection: some View {
        Section {
            Button {
                isRecalculating = true
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recalculate goals")
                            .appBody(15, weight: .semibold)
                            .foregroundStyle(AppColor.accent)
                        Text("From your height, weight, activity and goal")
                            .appBody(12)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                } icon: {
                    Image(systemName: "wand.and.stars").foregroundStyle(AppColor.accent)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } footer: {
            footnote("Works out new calorie, macro and water goals and replaces the ones above.")
        }
        .listRowBackground(AppColor.surface)
    }

    // MARK: - Failure

    /// Without the current row there is nothing safe to write, so this offers
    /// a retry rather than an empty form that would look editable.
    private var loadFailedState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Couldn't load your current goals.")
                .appBody(15, weight: .semibold)
                .foregroundStyle(AppColor.ink)
            Text("Saving now would overwrite the goals already on your account, so the form stays locked until this loads.")
                .appBody(13)
                .foregroundStyle(AppColor.secondaryText)
            PrimaryButton(title: "Try again", isLoading: viewModel.isLoading) {
                Task { await viewModel.load() }
            }
        }
        .padding(AppSpacing.screenPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppColor.background)
    }

    // MARK: - Furniture

    private func header(_ title: String) -> some View {
        Text(title)
            .appBody(12, weight: .semibold)
            .foregroundStyle(AppColor.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .appBody(12)
            .foregroundStyle(AppColor.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
    }
}

#Preview {
    NavigationStack { SetGoalsView() }
}
