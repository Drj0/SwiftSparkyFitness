//
//  FoodSearchView.swift
//  SwiftSparkyFitness
//
//  Log Food search sheet: meal chips right under search (destination chosen
//  before results load), with distinct no-results / network-error states.
//
//  Structured to exactly match CustomFoodView/LogExerciseView: a plain
//  VStack, no NavigationStack, header then a single ScrollView that fills
//  remaining space naturally (ScrollView is greedy along its scroll axis by
//  default — no explicit .frame(maxHeight: .infinity) needed). An earlier
//  version used a bare Group with .frame(maxHeight: .infinity) instead of a
//  ScrollView for the results area; verified live via the simulator's
//  accessibility hierarchy that this measurably pushed the header ~130pt
//  down inside a multi-detent sheet, while the ScrollView-based screens
//  don't have that offset at all. Selecting a result opens FoodDetailView
//  as its own sheet rather than a NavigationStack push.
//
//  THE RESULTS AREA HAS THREE STATES, NOT ONE
//  ------------------------------------------
//  `isSearching` was published, set and cleared, and read by nobody, and the
//  idle case rendered EmptyView() — so opening the sheet showed 259pt of
//  blank white between the chips and the footer, and typing showed the same
//  blank white for as long as the debounce plus two network calls took. The
//  user got no confirmation that a search was even happening. Idle now
//  prompts, in-flight shows a spinner, and a refinement over an existing
//  list dims that list instead of throwing it away.
//

import SwiftUI

struct FoodSearchView: View {
    @StateObject private var viewModel: FoodSearchViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pushedFood: Food?
    @State private var isPresentingCustomFood = false
    /// This sheet exists solely to receive a typed query, so it opens with
    /// the keyboard already up rather than costing a tap to get there.
    @FocusState private var isSearchFocused: Bool

    /// The day a picked food is logged to — Today can be viewing a past day.
    private let entryDate: Date
    /// Called once a food is logged. The presenter should close this sheet
    /// by its own binding: that removes Log Food and the detail sheet on top
    /// of it in one animation, where this sheet's `dismiss()` closed the
    /// detail first and flashed Log Food back up before it went too.
    private let onLogged: (() -> Void)?

    init(mealTypes: [MealType], initialMealType: MealType? = nil, entryDate: Date = Date(),
         onLogged: (() -> Void)? = nil) {
        self.entryDate = entryDate
        self.onLogged = onLogged
        _viewModel = StateObject(wrappedValue: FoodSearchViewModel(mealTypes: mealTypes, initialMealType: initialMealType, entryDate: entryDate))
    }

    // Picking a food slides its detail in *inside* this sheet (the detail
    // already carries its own "‹ Back"), rather than stacking a second sheet
    // on top. Two stacked sheets close one after the other, so logging
    // flashed Log Food back up for a beat before the whole thing went away.
    private var showsOwnManualEntry: Bool {
        ["noResults", "networkError"].contains(viewModel.outcome.kindID)
    }

    var body: some View {
        NavigationStack {
            searchContent
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(item: $pushedFood) { food in
                    if let mealType = viewModel.selectedMealType {
                        // A food logged before opens at the amount last used.
                        FoodDetailView(food: food, mealTypes: viewModel.mealTypes, initialMealType: mealType,
                                       initialQuantity: viewModel.logStat(for: food)?.lastQuantity,
                                       entryDate: entryDate, dismissesOnSave: false) {
                            if let onLogged { onLogged() } else { dismiss() }
                        }
                        .toolbar(.hidden, for: .navigationBar)
                    }
                }
        }
    }

    private var searchContent: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                resultsArea
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: viewModel.isSearching)
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: resultsStateKey)

            // The empty and error states carry this same action as their
            // main button; a second copy under them read as noise.
            if !showsOwnManualEntry {
                Button {
                    isPresentingCustomFood = true
                } label: {
                    Text("+ Enter food manually")
                        .appBody(13, weight: .semibold)
                        .foregroundStyle(AppColor.accent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .overlay(Rectangle().fill(AppColor.hairline).frame(height: 1), alignment: .top)
            }
        }
        .background(AppColor.surface)
        .scrollDismissesKeyboard(.interactively)
        .task { await viewModel.loadRecents() }
        .alert("Not logged", isPresented: Binding(
            get: { viewModel.quickLogError != nil },
            set: { if !$0 { viewModel.quickLogError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.quickLogError ?? "")
        }
        .sheet(isPresented: $isPresentingCustomFood) {
            // Saving a custom food only adds it to the library. This used to
            // call this sheet's `dismiss()`, closing Log Food with nothing
            // logged — the food never reached the meal. Open it in the
            // detail instead, the same as a search result, to log it.
            CustomFoodView { food in pushedFood = food }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // The header's own vertical padding is trimmed to compensate for the
    // 44pt touch targets below: Cancel measured 45 x 17pt and the meal chips
    // 82.6 x 27.2, both well under the 44pt minimum. The targets grow, the
    // painted pills and the type stay exactly the size they were.
    private var header: some View {
        VStack(spacing: 10) {
            // No trailing action: this sheet commits nothing itself, it
            // pushes a detail sheet that does. SheetHeader centres the title
            // on the bar, so it no longer needs a spacer to balance Cancel —
            // and its own divider is suppressed because the rule that matters
            // here is the one under the chips, not under the title.
            SheetHeader(title: "Log Food", onCancel: { dismiss() }, showsDivider: false)

            searchAndChips
        }
        .padding(.top, 2)
        .padding(.bottom, 8)
        .overlay(Rectangle().fill(AppColor.hairline).frame(height: 1), alignment: .bottom)
        .task { isSearchFocused = true }
        .task(id: viewModel.query) {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await viewModel.search()
        }
    }

    private var searchAndChips: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                // Decorative twin of the field's own label — as its own
                // element it announced "Search" immediately before an
                // unlabelled text field.
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppColor.placeholder)
                    .accessibilityHidden(true)
                TextField("Search foods", text: $viewModel.query)
                    .appBody(15)
                    .foregroundStyle(AppColor.ink)
                    .focused($isSearchFocused)
                    .submitLabel(.search)
                    .accessibilityLabel("Search foods")
                    .onSubmit { Task { await viewModel.search() } }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(AppColor.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 6) {
                ForEach(viewModel.mealTypes) { mealType in
                    mealChip(mealType)
                }
            }
        }
        .padding(.horizontal, AppSpacing.screenPad)
    }

    @ViewBuilder
    private var resultsArea: some View {
        if viewModel.isSearching && !viewModel.hasResults {
            searchingState
                .transition(entrance)
        } else {
            switch viewModel.outcome {
            case .idle:
                idlePrompt
                    .transition(entrance)
            case .results(let foods):
                VStack(spacing: 0) {
                    if viewModel.someSourcesFailed && !viewModel.isSearching { partialResultsNotice }
                    resultsListContent(foods, heading: viewModel.resultsAreClosestMatches ? "CLOSEST MATCHES" : "RESULTS")
                }
                // A refinement is in flight: the previous list is still
                // the best answer available, so it recedes rather than
                // being replaced by a spinner on every keystroke.
                .opacity(viewModel.isSearching ? 0.45 : 1)
                .transition(entrance)
            case .noResults(let query):
                NoResultsView(query: query) { isPresentingCustomFood = true }
                    .padding(.top, 48)
                    .transition(entrance)
            case .networkError:
                SearchNetworkErrorView(
                    onRetry: { Task { await viewModel.search() } },
                    onManualEntry: { isPresentingCustomFood = true }
                )
                .padding(.top, 48)
                .transition(entrance)
            }
        }
    }

    /// A source didn't answer but others did. Without this the list passes
    /// for everything there is — "bread" showed only Bread upma whenever
    /// Open Food Facts was busy, and read as "this app has no bread".
    private var partialResultsNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppColor.secondaryText)
                .accessibilityHidden(true)
            Text("Some results didn't load.")
                .appBody(13)
                .foregroundStyle(AppColor.secondaryText)
            Spacer(minLength: 8)
            Button("Retry") { Task { await viewModel.search() } }
                .appBody(13, weight: .semibold)
                .foregroundStyle(AppColor.accent)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .buttonStyle(.pressable)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    private var entrance: AnyTransition {
        .opacity.combined(with: .move(edge: .top))
    }

    /// Changes only when the *kind* of content changes, so a list swapping
    /// for a near-identical list doesn't replay the entrance animation.
    private var resultsStateKey: String {
        if viewModel.hasResults { return "results" }
        return viewModel.isSearching ? "searching" : viewModel.outcome.kindID
    }

    /// Before anything is typed: the foods most recently logged, which is
    /// what re-logging usually wants. Falls back to the prompt on a fresh
    /// account (or if the request failed — recents are a shortcut, not
    /// something worth an error banner).
    @ViewBuilder
    private var idlePrompt: some View {
        if !viewModel.recentFoods.isEmpty {
            resultsListContent(viewModel.recentFoods, heading: "RECENT", quickLog: true)
        } else if viewModel.isLoadingRecents {
            // Nothing has been typed and nothing is known yet; a spinner here
            // would be the only thing on screen, so stay quiet and let the
            // prompt appear once the answer arrives.
            Color.clear.frame(height: 1)
        } else {
            searchPrompt
        }
    }

    /// ContentUnavailableView rather than a hand-built stack: it groups as a
    /// single VoiceOver element and handles Dynamic Type layout for free.
    private var searchPrompt: some View {
        // In the app's type, like the "No results" state beside it; the
        // system default read as a different app on a new user's first sheet.
        ContentUnavailableView {
            Label {
                Text("Search for a food")
                    .appDisplay(18)
                    .foregroundStyle(AppColor.ink)
            } icon: {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppColor.placeholder)
            }
        } description: {
            Text("Type a name or a brand. Nothing matching? Add it yourself below.")
                .appBody(13)
                .foregroundStyle(AppColor.secondaryText)
        }
        .padding(.top, 40)
    }

    private var searchingState: some View {
        VStack(spacing: 10) {
            ProgressView().tint(AppColor.accent)
            Text("Searching…")
                .appBody(13)
                .foregroundStyle(AppColor.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
        .accessibilityElement(children: .combine)
    }

    private func mealChip(_ mealType: MealType) -> some View {
        let isSelected = viewModel.selectedMealType?.id == mealType.id
        return Button {
            if viewModel.selectedMealType?.id != mealType.id {
                Haptics.selection()
                viewModel.selectedMealType = mealType
            }
        } label: {
            Text(mealType.name.capitalized)
                .appBody(12, weight: .semibold)
                .foregroundStyle(isSelected ? .white : AppColor.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(isSelected ? AppColor.accent : AppColor.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                // Touch target only — the pill itself stays 27pt tall.
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// `quickLog`: Recents only. There the "+" logs the food straight away at
    /// the amount its subtitle shows (the last one used) — re-logging is what
    /// the list is for — while tapping the row still opens the detail to
    /// change it. In search results the "+" stays a cue for the row's tap:
    /// a new food deserves a look at its amount first.
    private func resultsListContent(_ foods: [Food], heading: String = "RESULTS", quickLog: Bool = false) -> some View {
        VStack(spacing: 0) {
            Text(heading)
                .appBody(11, weight: .semibold)
                .foregroundStyle(AppColor.placeholder)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)

            ForEach(foods) { food in
                HStack(spacing: 0) {
                    Button {
                        pushedFood = food
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(food.name).appBody(15, weight: .semibold).foregroundStyle(AppColor.ink)
                                HStack(spacing: 6) {
                                    Text(subtitle(for: food, quantity: quickLog ? viewModel.quickLogQuantity(for: food) : nil))
                                        .appBody(12).foregroundStyle(AppColor.secondaryText)
                                        .lineLimit(1)
                                    frequencyCue(for: food)
                                }
                            }
                            Spacer(minLength: 8)
                            if !quickLog { plusMark(done: false) }
                        }
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)

                    if quickLog { quickLogButton(for: food) }
                }
                .overlay(Rectangle().fill(AppColor.inputBackground).frame(height: 1), alignment: .bottom)
            }
        }
        .padding(.horizontal, 20)
    }

    private func plusMark(done: Bool) -> some View {
        Image(systemName: done ? "checkmark" : "plus")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(done ? .white : AppColor.accent)
            .frame(width: 26, height: 26)
            .background(done ? AppColor.accent : AppColor.accentSoft, in: Circle())
            .contentTransition(.symbolEffect(.replace))
    }

    private func quickLogButton(for food: Food) -> some View {
        let done = viewModel.justLogged.contains(food.id)
        let amount = FoodVariant.amountText(viewModel.quickLogQuantity(for: food), unit: food.defaultVariant?.servingUnit ?? "g")
        let meal = viewModel.selectedMealType?.name.capitalized ?? "your meal"
        return Button {
            Task { await viewModel.quickLog(food) }
        } label: {
            plusMark(done: done)
                // The painted circle stays 26pt; the target is 44.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        // No meal to log into (none loaded): a "+" that did nothing would
        // read as broken, so it dims rather than pretending.
        .disabled(viewModel.selectedMealType == nil)
        .opacity(viewModel.selectedMealType == nil ? 0.4 : 1)
        .padding(.trailing, -9)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: done)
        .accessibilityLabel(done ? "Logged \(food.name)" : "Log \(amount) of \(food.name) to \(meal)")
    }

    /// "↻ 5× this week", only from the second time: once is just Recents.
    /// Accent-coloured on the subtitle line, so it costs no height.
    @ViewBuilder
    private func frequencyCue(for food: Food) -> some View {
        if let times = viewModel.logStat(for: food)?.timesThisWeek, times >= 2 {
            HStack(spacing: 2) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 9, weight: .bold))
                Text("\(times)× this week")
                    .appBody(12, weight: .semibold)
            }
            .foregroundStyle(AppColor.accent)
            .fixedSize()
            .layoutPriority(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Logged \(times) times this week")
        }
    }

    /// `quantity`: show that amount and its calories (a recent food at the
    /// amount last logged) rather than one default serving.
    private func subtitle(for food: Food, quantity: Double? = nil) -> String {
        let variant = food.defaultVariant
        var parts: [String] = []
        if let brand = food.brand { parts.append(brand) }
        let serving = variant?.servingSize ?? 0
        let amount = quantity ?? serving
        if let unit = variant?.servingUnit, variant?.servingSize != nil {
            parts.append(FoodVariant.amountText(amount, unit: unit))
        }
        if let calories = variant?.calories {
            if quantity != nil, serving > 0 {
                parts.append("\(Int((calories * amount / serving).rounded())) kcal")
            } else {
                parts.append("\(Int(calories)) kcal")
            }
        }
        // Where the data came from, appended to the line that's already a
        // "·"-joined list rather than given its own badge — results from three
        // databases otherwise look identically authoritative. A local food
        // adds nothing here: no source label *is* the signal it's the user's
        // own.
        if let source = food.source.label { parts.append(source) }
        return parts.joined(separator: " · ")
    }
}

// NoResultsView/SearchNetworkErrorView moved to SearchResultStates.swift so
// ExerciseSearchView (Module 12) could reuse them instead of duplicating —
// both took a `subject`/`manualEntryLabel` pair so "food database"/"Enter
// food manually" isn't hardcoded into copy the exercise screen also shows.

#Preview {
    FoodSearchView(mealTypes: [
        MealType(id: "1", name: "breakfast", sortOrder: 10),
        MealType(id: "2", name: "lunch", sortOrder: 20),
    ])
}
