//
//  OnboardingView.swift
//  SwiftSparkyFitness
//
//  One question per screen, a progress bar, Back and Skip up top and one
//  button at the bottom — the shape every fitness app's setup has, because
//  a long form on day one is where people give up. Ends on the plan it
//  worked out, with the calorie figure adjustable before anything is saved.
//

import SwiftUI

struct OnboardingView: View {
    @StateObject private var viewModel: OnboardingViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // One per field: AppTextField takes a Bool focus binding.
    @FocusState private var weightFocused: Bool
    @FocusState private var heightFocused: Bool
    @FocusState private var targetFocused: Bool
    /// The Health sheet is being asked for: a second tap would ask twice.
    @State private var isConnectingHealth = false
    /// Closes the flow: finished, skipped, or (from Settings) cancelled.
    let onFinish: () -> Void
    /// Settings' rerun: "Cancel" instead of "Skip", and nothing remembered.
    private let isRerun: Bool

    private enum Field { case weight, height, target }

    init(account: String?, isRerun: Bool = false, onFinish: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: OnboardingViewModel(account: account))
        self.isRerun = isRerun
        self.onFinish = onFinish
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    stepContent
                        .id(viewModel.step)
                        .transition(stepTransition)
                }
                .padding(.horizontal, AppSpacing.screenPad)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            bottomBar
        }
        .background(AppColor.background)
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: viewModel.step)
        .task { await viewModel.load() }
        .interactiveDismissDisabled()
    }

    /// Forward slides in from the right, Back from the left — the direction
    /// is what tells you which way you went.
    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let incoming: Edge = viewModel.isGoingBack ? .leading : .trailing
        let outgoing: Edge = viewModel.isGoingBack ? .trailing : .leading
        // Both sides move: a fade-in-place under a slide left two screens'
        // text overlapping for the length of the animation.
        return .asymmetric(
            insertion: .move(edge: incoming).combined(with: .opacity),
            removal: .move(edge: outgoing).combined(with: .opacity)
        )
    }

    /// Skip passes one question; the whole setup is only left from the plan
    /// ("Later"), so a stray tap on the first screen can't end it. A rerun
    /// from Settings can always be cancelled.
    private var trailingTitle: String {
        if isRerun { return "Cancel" }
        return viewModel.step == .plan ? "Later" : "Skip"
    }

    private var trailingHint: String {
        if isRerun { return "Closes without changing your goals" }
        return viewModel.step == .plan ? "Closes setup without saving a plan" : "Skips this question"
    }

    private func trailingAction() {
        dismissKeyboard()
        if isRerun {
            onFinish()
        } else if viewModel.step == .plan {
            viewModel.skipAll()
            onFinish()
        } else {
            Haptics.selection()
            viewModel.skipStep()
        }
    }

    private var isEditing: Bool { weightFocused || heightFocused || targetFocused }

    private func dismissKeyboard() {
        weightFocused = false; heightFocused = false; targetFocused = false
    }

    // MARK: - Chrome

    private var hidesBack: Bool { viewModel.step == viewModel.steps.first || viewModel.step == .health }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.selection()
                viewModel.back()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppColor.accent)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressableCompact)
            // Nothing to go back to on the first step, or once the plan is saved.
            .opacity(hidesBack ? 0 : 1)
            .disabled(hidesBack)
            .accessibilityLabel("Back")

            ProgressView(value: viewModel.progress)
                .tint(AppColor.accent)
                .scaleEffect(x: 1, y: 1.5)
                .animation(reduceMotion ? nil : .snappy, value: viewModel.progress)
                .accessibilityLabel("Step \((viewModel.steps.firstIndex(of: viewModel.step) ?? 0) + 1) of \(viewModel.steps.count)")

            Button(trailingTitle, action: trailingAction)
            .appBody(15, weight: .semibold)
            .foregroundStyle(AppColor.secondaryText)
            .frame(minWidth: 44, minHeight: 44)
            .padding(.trailing, 8)
            .contentShape(Rectangle())
            // Nothing to skip once the plan is saved; "Not now" is below.
            .opacity(viewModel.step == .health ? 0 : 1)
            .disabled(viewModel.step == .health)
            .accessibilityHint(trailingHint)
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let banner = viewModel.bannerMessage {
                ErrorBanner(message: banner)
            }
            switch viewModel.step {
            case .plan:
                PrimaryButton(title: "Save my plan", isLoading: viewModel.isSaving) {
                    Task {
                        guard await viewModel.save() else { return }
                        Haptics.success()
                        if viewModel.steps.last == .plan { onFinish() } else { viewModel.next() }
                    }
                }
                .disabled(!viewModel.canContinue)
                .opacity(viewModel.canContinue ? 1 : 0.4)
            case .health:
                PrimaryButton(title: "Connect Apple Health", isLoading: isConnectingHealth) {
                    guard !isConnectingHealth else { return }
                    isConnectingHealth = true
                    Task {
                        let outcome = try? await HealthKitService.shared.requestAuthorization()
                        HealthSync.isEnabled = outcome == .answered
                        onFinish()
                    }
                }
                Button("Not now", action: onFinish)
                    .appBody(15, weight: .semibold)
                    .foregroundStyle(AppColor.accent)
                    .frame(maxWidth: .infinity, minHeight: 44)
            default:
                HStack(spacing: 10) {
                    // The number pad has no return key, a keyboard-toolbar
                    // "Done" doesn't show without a navigation bar, and a
                    // background tap swallowed taps on the choices. So the
                    // way out sits next to the button the thumb is already on.
                    if isEditing {
                        Button(action: dismissKeyboard) {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(AppColor.accent)
                                .frame(width: 54, height: 54)
                                .background(AppColor.accentSoft, in: RoundedRectangle(cornerRadius: AppRadius.md))
                        }
                        .buttonStyle(.pressableCompact)
                        .accessibilityLabel("Hide keyboard")
                        .transition(.scale.combined(with: .opacity))
                    }
                    PrimaryButton(title: "Continue") {
                        dismissKeyboard()
                        viewModel.answerStep()
                    }
                    .disabled(!viewModel.canContinue)
                    .opacity(viewModel.canContinue ? 1 : 0.4)
                }
                .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isEditing)
            }
        }
        .padding(.horizontal, AppSpacing.screenPad)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(AppColor.background)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch viewModel.step {
        case .about: aboutStep
        case .body: bodyStep
        case .activity: activityStep
        case .goal: goalStep
        case .plan: planStep
        case .health: healthStep
        }
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .appDisplay(28)
                .foregroundStyle(AppColor.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .appBody(15)
                .foregroundStyle(AppColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 24)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .appBody(12, weight: .semibold)
            .foregroundStyle(AppColor.secondaryText)
            .padding(.bottom, 8)
    }

    // MARK: - Steps

    private var aboutStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading(isRerun ? "Update your plan" : "Let's set up your plan",
                    "A few questions to work out a daily calorie target that fits you. Takes about a minute.")

            label("SEX")
            HStack(spacing: 10) {
                ForEach(UserProfile.Sex.allCases, id: \.self) { sex in
                    OptionCard(title: sex.label, isSelected: viewModel.sex == sex) {
                        viewModel.sex = sex
                    }
                }
            }
            Text("Used only to estimate how much energy your body uses.")
                .appBody(12)
                .foregroundStyle(AppColor.placeholder)
                .padding(.top, 8)

            HStack(alignment: .firstTextBaseline) {
                label("BIRTHDAY")
                Spacer()
                Text("\(viewModel.age) years old")
                    .appBody(13, weight: .semibold)
                    .foregroundStyle(AppColor.accent)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .snappy, value: viewModel.age)
            }
            .padding(.top, 28)
            // A wheel, not the compact button: a birthday is decades back,
            // and the compact calendar makes you page there a month at a time.
            DatePicker("Birthday", selection: $viewModel.birthDate, in: viewModel.birthDateRange, displayedComponents: .date)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.md))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppColor.hairline, lineWidth: 1))
        }
    }

    private var bodyStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Your height and weight", "Your starting point — today's weight is logged, so your progress chart begins here.")

            unitPicker("WEIGHT", selection: $viewModel.weightUnit, options: [("kg", "kg"), ("lbs", "lb")])
            AppTextField(
                placeholder: viewModel.weightUnit == "lbs" ? "154" : "70", text: $viewModel.weightText,
                style: .filled, errorMessage: viewModel.weightError, keyboardType: .decimalPad,
                suffix: viewModel.weightUnitLabel, focus: binding(.weight)
            )

            unitPicker("HEIGHT", selection: $viewModel.heightUnit, options: [("cm", "cm"), ("inches", "in")])
                .padding(.top, 24)
            AppTextField(
                placeholder: viewModel.heightUnit == "inches" ? "67" : "170", text: $viewModel.heightText,
                style: .filled, errorMessage: viewModel.heightError, keyboardType: .decimalPad,
                suffix: viewModel.heightUnitLabel, focus: binding(.height)
            )
        }
        .task { if viewModel.weightText.isEmpty { weightFocused = true } }
    }

    private func unitPicker(_ title: String, selection: Binding<String>, options: [(String, String)]) -> some View {
        HStack {
            label(title)
            Spacer()
            Picker(title, selection: selection) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 110)
            .padding(.bottom, 8)
        }
    }

    private var activityStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("How active are you?", "On a typical week, not counting what you'll log as exercise.")
            ForEach(OnboardingViewModel.activities) { activity in
                OptionCard(title: activity.title, detail: activity.detail, symbol: activity.symbol,
                           isSelected: viewModel.activityLevel == activity.id) {
                    viewModel.activityLevel = activity.id
                    advanceAfterChoice()
                }
            }
        }
    }

    private var goalStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("What's your goal?", "You can change this anytime in Settings.")
            ForEach(UserProfile.PrimaryGoal.allCases, id: \.self) { goal in
                OptionCard(title: goal.label, symbol: goal.symbol, isSelected: viewModel.goal == goal) {
                    viewModel.goal = goal
                    // Maintaining has nothing more to ask.
                    if goal == .maintain { advanceAfterChoice() }
                }
            }

            if let goal = viewModel.goal, goal != .maintain {
                HStack(alignment: .firstTextBaseline) {
                    label("TARGET WEIGHT")
                    Spacer()
                    if let summary = viewModel.targetSummary {
                        Text(summary)
                            .appBody(13, weight: .semibold)
                            .foregroundStyle(AppColor.accent)
                            .transition(.opacity)
                    }
                }
                .padding(.top, 16)
                .animation(reduceMotion ? nil : .snappy, value: viewModel.targetSummary)
                AppTextField(
                    placeholder: viewModel.weightText.isEmpty ? "0" : viewModel.weightText, text: $viewModel.targetWeightText,
                    style: .filled, errorMessage: viewModel.targetError, keyboardType: .decimalPad,
                    suffix: viewModel.weightUnitLabel, focus: binding(.target)
                )

                // Tiers, not raw kg: each is a share of body weight, and its
                // detail is what it means for this person (CalorieTarget).
                label("PACE").padding(.top, 16)
                ForEach(CalorieTarget.Pace.allCases) { pace in
                    OptionCard(title: pace.rawValue, detail: viewModel.paceDetail(pace),
                               isSelected: viewModel.pace == pace) {
                        viewModel.pace = pace
                    }
                }
                Text(goal == .lose
                     ? "Slower is easier to stick with and keeps more muscle. Medium suits most people."
                     : "Slow gains keep it mostly muscle.")
                    .appBody(12)
                    .foregroundStyle(AppColor.placeholder)
                    .padding(.top, 4)
                Label(goal == .lose
                      ? "Fast isn't for everyone. Skip it if you're under 18, pregnant or breastfeeding, have a health condition, or are close to your target. Check with a doctor first."
                      : "Fast isn't for everyone: at that rate more of what you gain is fat than muscle.",
                      systemImage: "exclamationmark.triangle.fill")
                    .appBody(12)
                    .foregroundStyle(AppColor.secondaryText)
                    .padding(.top, 4)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: viewModel.goal)
    }

    private var planStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Your daily plan", viewModel.maintenance == nil
                    ? "A starting point you can adjust. Answer a question below for one that fits you."
                    : "Built from your answers. Adjust anything before saving.")

            calorieCard

            if !viewModel.assumptions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.assumptions, id: \.text) { item in
                        Button {
                            Haptics.selection()
                            viewModel.revisit(item.step)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(AppColor.accent)
                                    .accessibilityHidden(true)
                                Text(item.text)
                                    .appBody(13, weight: .semibold)
                                    .foregroundStyle(AppColor.ink)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.forward")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(AppColor.placeholder)
                                    .accessibilityHidden(true)
                            }
                            .padding(.vertical, 10)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)
                    }
                }
                .padding(.horizontal, 14)
                .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.md))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppColor.hairline, lineWidth: 1))
                .padding(.top, 10)
            }

            if let arrival = viewModel.estimatedArrival, let target = viewModel.targetWeight {
                Label {
                    Text("\(target.formatted()) \(viewModel.weightUnitLabel) around \(arrival.formatted(.dateTime.month(.wide).year()))")
                        .appBody(14, weight: .semibold)
                        .foregroundStyle(AppColor.ink)
                } icon: {
                    Image(systemName: "flag.checkered")
                        .foregroundStyle(AppColor.accent)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColor.accentSoft, in: RoundedRectangle(cornerRadius: AppRadius.md))
                .padding(.top, 10)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Estimated to reach \(target.formatted()) \(viewModel.weightUnitLabel) around \(arrival.formatted(.dateTime.month(.wide).year()))")
            }

            if viewModel.isAtFloor {
                Text("That's the lowest target Sparky suggests, so you may lose a little slower than the pace you picked.")
                    .appBody(12)
                    .foregroundStyle(AppColor.placeholder)
                    .padding(.top, 8)
            }

            label("MACROS").padding(.top, 24)
            Picker("Macro split", selection: $viewModel.macroSplit) {
                ForEach(OnboardingViewModel.MacroSplit.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: viewModel.macroSplit) { _, _ in Haptics.selection() }

            HStack(spacing: 10) {
                macroTile("Protein", viewModel.grams(viewModel.split.protein, perGram: 4), viewModel.split.protein, AppColor.protein)
                macroTile("Carbs", viewModel.grams(viewModel.split.carbs, perGram: 4), viewModel.split.carbs, AppColor.carbs)
                macroTile("Fat", viewModel.grams(viewModel.split.fat, perGram: 9), viewModel.split.fat, AppColor.energy)
            }
            .padding(.top, 10)
            .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: viewModel.macroSplit)

            label("WATER").padding(.top, 24)
            HStack {
                Image(systemName: "drop.fill")
                    .foregroundStyle(AppColor.water)
                    .accessibilityHidden(true)
                // Not Measurement.formatted: some locales turn litres into "2,750 cm³".
                Text("\((viewModel.waterMl / 1000).formatted(.number.precision(.fractionLength(0...2)))) L a day")
                    .appBody(16, weight: .semibold)
                    .foregroundStyle(AppColor.ink)
                    .contentTransition(.numericText())
                Spacer()
                Stepper("Water", value: $viewModel.waterMl, in: 500...6000, step: 250)
                    .labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppColor.hairline, lineWidth: 1))
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: viewModel.waterMl)

            Text("You can change any of these later in Settings → Goals.")
                .appBody(12)
                .foregroundStyle(AppColor.placeholder)
                .padding(.top, 16)

            if viewModel.goals.loadFailed {
                Button("Couldn't read your current goals — try again") { Task { await viewModel.goals.load() } }
                    .appBody(13, weight: .semibold)
                    .foregroundStyle(AppColor.destructive)
                    .frame(minHeight: 44)
            }
        }
    }

    /// The number, with where it came from underneath: a calorie target with
    /// no working shown reads as arbitrary, and arbitrary gets ignored.
    private var calorieCard: some View {
        VStack(spacing: 14) {
            HStack {
                calorieButton("minus", -50)
                Spacer()
                VStack(spacing: 2) {
                    Text(Int(viewModel.calories).formatted())
                        .appDisplay(48)
                        .foregroundStyle(AppColor.ink)
                        .contentTransition(.numericText())
                    Text("kcal a day")
                        .appBody(14)
                        .foregroundStyle(AppColor.secondaryText)
                }
                .accessibilityElement(children: .combine)
                Spacer()
                calorieButton("plus", 50)
            }

            Rectangle().fill(AppColor.hairline).frame(height: 1)

            VStack(spacing: 6) {
                if let maintenance = viewModel.maintenance {
                    breakdownRow("Your body uses about", "\(Int((maintenance / 10).rounded() * 10).formatted()) kcal")
                } else {
                    breakdownRow("A typical starting point", "\(Int(GoalsViewModel.suggestedCalories).formatted()) kcal")
                }
                if viewModel.usableGoal != .maintain, viewModel.paceAdjustment != 0 {
                    breakdownRow(paceLabel, "\(viewModel.paceAdjustment > 0 ? "+" : "−")\(Int(abs(viewModel.paceAdjustment)).formatted()) kcal")
                }
                if viewModel.calories != viewModel.suggestedCalories {
                    breakdownRow("Your adjustment", "\(viewModel.calories > viewModel.suggestedCalories ? "+" : "−")\(Int(abs(viewModel.calories - viewModel.suggestedCalories)).formatted()) kcal")
                }
            }

            if viewModel.calories != viewModel.suggestedCalories {
                Button("Use suggested \(Int(viewModel.suggestedCalories).formatted()) kcal") {
                    withAnimation(reduceMotion ? nil : .snappy) { viewModel.calories = viewModel.suggestedCalories }
                }
                .appBody(13, weight: .semibold)
                .foregroundStyle(AppColor.accent)
                .frame(minHeight: 36)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.lg).stroke(AppColor.hairline, lineWidth: 1))
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: viewModel.calories)
    }

    private var paceLabel: String {
        let kg = viewModel.kgPerWeek(viewModel.pace) / CalorieTarget.kilograms(1, unit: viewModel.weightUnit)
        let pace = "\(((kg * 10).rounded() / 10).formatted()) \(viewModel.weightUnitLabel)"
        return viewModel.usableGoal == .lose ? "To lose \(pace) a week" : "To gain \(pace) a week"
    }

    private func breakdownRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).appBody(13).foregroundStyle(AppColor.secondaryText)
            Spacer()
            Text(value)
                .appBody(13, weight: .semibold)
                .foregroundStyle(AppColor.ink)
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
    }

    private func calorieButton(_ symbol: String, _ amount: Double) -> some View {
        Button {
            Haptics.light()
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { viewModel.adjustCalories(by: amount) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppColor.accent)
                .frame(width: 44, height: 44)
                .background(AppColor.accentSoft, in: Circle())
        }
        .buttonStyle(.pressableCompact)
        .accessibilityLabel(amount < 0 ? "50 fewer calories" : "50 more calories")
    }

    private func macroTile(_ title: String, _ grams: Int, _ percent: Double, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(grams)g")
                .appBody(17, weight: .bold)
                .foregroundStyle(color)
                .contentTransition(.numericText())
            Text("\(title) · \(Int(percent))%")
                .appBody(12)
                .foregroundStyle(AppColor.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppColor.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var healthStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Plan saved. One last thing", "Connect Apple Health and what your iPhone or Watch already records counts towards your day — no extra logging.")

            VStack(spacing: 0) {
                healthRow("flame.fill", AppColor.energy, "Active energy", "Adds to the calories you can eat")
                Rectangle().fill(AppColor.hairline).frame(height: 1).padding(.leading, 56)
                healthRow("shoeprints.fill", AppColor.carbs, "Steps", "Shown on Today")
            }
            .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppColor.hairline, lineWidth: 1))

            Label("Sparky only reads from Health. Workout import and everything else is in Settings.", systemImage: "lock.fill")
                .appBody(12)
                .foregroundStyle(AppColor.placeholder)
                .padding(.top, 12)
        }
    }

    private func healthRow(_ symbol: String, _ tint: Color, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).appBody(15, weight: .semibold).foregroundStyle(AppColor.ink)
                Text(detail).appBody(13).foregroundStyle(AppColor.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    /// One question on the screen and it's answered: move on, after a beat
    /// long enough to see the choice land. Changing it later is one Back away.
    private func advanceAfterChoice() {
        let step = viewModel.step
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard viewModel.step == step, viewModel.canContinue else { return }
            viewModel.answerStep()
        }
    }

    private func binding(_ field: Field) -> FocusState<Bool>.Binding {
        switch field {
        case .weight: return $weightFocused
        case .height: return $heightFocused
        case .target: return $targetFocused
        }
    }
}

/// A tappable choice that shows it's chosen: the accent ring the start
/// screen's recommended card uses.
private struct OptionCard: View {
    let title: String
    var detail: String?
    var symbol: String?
    let isSelected: Bool
    var compact = false
    let action: () -> Void

    var body: some View {
        Button {
            if !isSelected { Haptics.selection() }
            action()
        } label: {
            HStack(spacing: 14) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : AppColor.accent)
                        .frame(width: 40, height: 40)
                        .background(isSelected ? AppColor.accent : AppColor.accentSoft, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .appBody(compact ? 14 : 16, weight: .semibold)
                        .foregroundStyle(isSelected ? AppColor.accent : AppColor.ink)
                    if let detail {
                        Text(detail)
                            .appBody(13)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                }
                if !compact {
                    Spacer(minLength: 0)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(isSelected ? AppColor.accent : AppColor.hairline)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
            .padding(.horizontal, compact ? 8 : 16)
            .padding(.vertical, compact ? 12 : 14)
            .frame(minHeight: 44)
            .background(isSelected ? AppColor.accentSoft : AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(isSelected ? AppColor.accent : AppColor.hairline, lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private extension UserProfile.PrimaryGoal {
    var symbol: String {
        switch self {
        case .lose: return "arrow.down.right"
        case .maintain: return "equal"
        case .gain: return "arrow.up.right"
        }
    }
}
