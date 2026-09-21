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

    init(mealTypes: [MealType], initialMealType: MealType? = nil) {
        _viewModel = StateObject(wrappedValue: FoodSearchViewModel(mealTypes: mealTypes, initialMealType: initialMealType))
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                resultsArea
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: viewModel.isSearching)
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: resultsStateKey)

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
        .background(AppColor.surface)
        .scrollDismissesKeyboard(.interactively)
        .sheet(item: $pushedFood) { food in
            if let mealType = viewModel.selectedMealType {
                FoodDetailView(food: food, mealTypes: viewModel.mealTypes, initialMealType: mealType) {
                    dismiss()
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $isPresentingCustomFood) {
            CustomFoodView { dismiss() }
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
            HStack {
                // The frame goes on the *label*, not on the Button: a frame
                // outside a Button grows the view without growing what the
                // button actually hit-tests.
                Button { dismiss() } label: {
                    Text("Cancel")
                        .appBody(15)
                        .foregroundStyle(AppColor.secondaryText)
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                Spacer()
                Text("Log Food").appDisplay(18)
                Spacer()
                Color.clear.frame(width: 44, height: 1)
            }

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
        .padding(.horizontal, 20)
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
                resultsListContent(foods)
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

    private var entrance: AnyTransition {
        .opacity.combined(with: .move(edge: .top))
    }

    /// Changes only when the *kind* of content changes, so a list swapping
    /// for a near-identical list doesn't replay the entrance animation.
    private var resultsStateKey: String {
        if viewModel.hasResults { return "results" }
        return viewModel.isSearching ? "searching" : viewModel.outcome.kindID
    }

    /// ContentUnavailableView rather than a hand-built stack: it groups as a
    /// single VoiceOver element and handles Dynamic Type layout for free.
    private var idlePrompt: some View {
        ContentUnavailableView {
            Label("Search for a food", systemImage: "magnifyingglass")
        } description: {
            Text("Type a name or a brand. Nothing matching? Add it yourself below.")
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

    private func resultsListContent(_ foods: [Food]) -> some View {
        VStack(spacing: 0) {
            Text("RESULTS")
                .appBody(11, weight: .semibold)
                .foregroundStyle(AppColor.placeholder)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
                .padding(.bottom, 4)

            ForEach(foods) { food in
                Button {
                    pushedFood = food
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(food.name).appBody(15, weight: .semibold).foregroundStyle(AppColor.ink)
                            Text(subtitle(for: food)).appBody(12).foregroundStyle(AppColor.secondaryText)
                        }
                        Spacer()
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppColor.accent)
                            .frame(width: 26, height: 26)
                            .background(AppColor.accentSoft, in: Circle())
                    }
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .overlay(Rectangle().fill(AppColor.inputBackground).frame(height: 1), alignment: .bottom)
            }
        }
        .padding(.horizontal, 20)
    }

    private func subtitle(for food: Food) -> String {
        let variant = food.defaultVariant
        var parts: [String] = []
        if let brand = food.brand { parts.append(brand) }
        if let size = variant?.servingSize, let unit = variant?.servingUnit {
            parts.append("\(Int(size))\(unit)")
        }
        if let calories = variant?.calories {
            parts.append("\(Int(calories)) kcal")
        }
        return parts.joined(separator: " · ")
    }
}

private struct NoResultsView: View {
    let query: String
    let onManualEntry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("🔎").font(.system(size: 36))
            Text("No results for \"\(query)\"")
                .appDisplay(18)
                .foregroundStyle(AppColor.ink)
                .multilineTextAlignment(.center)
            Text("We couldn't find a match in the food database. You can add it yourself instead.")
                .appBody(13)
                .foregroundStyle(AppColor.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)
            Button(action: onManualEntry) {
                Text("Enter food manually")
                    .appBody(15, weight: .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(AppColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.pressable)
        }
        .padding(.horizontal, 44)
    }
}

private struct SearchNetworkErrorView: View {
    let onRetry: () -> Void
    let onManualEntry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(AppColor.errorBackground).frame(width: 60, height: 60)
                Image(systemName: "wifi.slash")
                    .font(.system(size: 22))
                    .foregroundStyle(AppColor.destructive)
            }
            .padding(.bottom, 4)
            .accessibilityHidden(true)
            Text("Can't reach the food database")
                .appDisplay(18)
                .foregroundStyle(AppColor.ink)
                .multilineTextAlignment(.center)
            Text("Check your connection and try again. You can still add this food yourself.")
                .appBody(13)
                .foregroundStyle(AppColor.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)

            Button(action: onRetry) {
                Text("Retry")
                    .appBody(15, weight: .semibold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(AppColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.pressableLarge)
            Button(action: onManualEntry) {
                Text("Enter food manually")
                    .appBody(15, weight: .semibold)
                    .foregroundStyle(AppColor.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(AppColor.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.pressableLarge)
        }
        .padding(.horizontal, 40)
    }
}

#Preview {
    FoodSearchView(mealTypes: [
        MealType(id: "1", name: "breakfast", sortOrder: 10),
        MealType(id: "2", name: "lunch", sortOrder: 20),
    ])
}
