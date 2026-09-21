//
//  FoodDetailView.swift
//  SwiftSparkyFitness
//
//  Macros recompute live off the gram stepper, but still show a static
//  "X kcal for Yg" framing so the number always carries its basis.
//

import SwiftUI

struct FoodDetailView: View {
    @StateObject private var viewModel: FoodDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onLogged: () -> Void

    init(
        food: Food, mealTypes: [MealType], initialMealType: MealType,
        existingEntryId: String? = nil, initialQuantity: Double? = nil, entryDate: Date = Date(),
        onLogged: @escaping () -> Void
    ) {
        _viewModel = StateObject(wrappedValue: FoodDetailViewModel(
            food: food, mealTypes: mealTypes, initialMealType: initialMealType,
            existingEntryId: existingEntryId, initialQuantity: initialQuantity, entryDate: entryDate
        ))
        self.onLogged = onLogged
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.food.name).appDisplay(22).foregroundStyle(AppColor.ink)
                        if let brand = viewModel.food.brand {
                            Text(brand).appBody(13).foregroundStyle(AppColor.secondaryText)
                        }
                    }

                    quantityStepper

                    HStack(spacing: 10) {
                        ForEach(viewModel.mealTypes) { mealType in
                            mealChip(mealType)
                        }
                    }

                    macroCard
                }
                .padding(20)
            }

            PrimaryButton(
                title: viewModel.isEditing ? "Save Changes" : "Add to \(viewModel.selectedMealType.name.capitalized)",
                isLoading: viewModel.isSaving
            ) {
                Task {
                    if await viewModel.save() {
                        dismiss()
                        onLogged()
                    }
                }
            }
            .padding(20)
            .overlay(Rectangle().fill(AppColor.hairline).frame(height: 1), alignment: .top)
        }
        .background(AppColor.surface)
        .alert("Couldn't log that", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { isPresented in if !isPresented { viewModel.errorMessage = nil } }
        ), actions: {
            Button("OK") { viewModel.errorMessage = nil }
        }, message: {
            Text(viewModel.errorMessage ?? "")
        })
    }

    // The right-hand "Add"/"Edit" used to be a plain Text in accent
    // semibold — pixel-identical to every real Save button in the app, in
    // the exact corner a Save button lives in, and it did nothing when
    // tapped. It's a mode indicator, not an action (the action is the
    // full-width button at the bottom), so it's restyled to the sheet's
    // section-label idiom rather than promoted to a second button that
    // would then compete with that one.
    //
    // Header padding drops from 14 to 2 because Back now carries a 44pt
    // touch target of its own; the row keeps its measured height.
    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Text("‹ Back")
                    .appBody(15)
                    .foregroundStyle(AppColor.accent)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Back")

            Spacer()

            Text(viewModel.isEditing ? "EDIT" : "ADD")
                .appBody(12, weight: .semibold)
                .foregroundStyle(AppColor.placeholder)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 2)
        .overlay(Rectangle().fill(AppColor.hairline).frame(height: 1), alignment: .bottom)
    }

    private var quantityStepper: some View {
        HStack {
            stepButton(label: "–", amount: -10, color: AppColor.placeholder)
                .accessibilityLabel("Decrease by 10 \(viewModel.servingUnit)")
            Spacer()
            VStack {
                Text("\(Int(viewModel.quantity))")
                    .appBody(20, weight: .bold)
                    .foregroundStyle(AppColor.ink)
                    .contentTransition(.numericText())
                Text(viewModel.servingUnit).appBody(12).foregroundStyle(AppColor.secondaryText)
            }
            Spacer()
            stepButton(label: "+", amount: 10, color: AppColor.accent)
                .accessibilityLabel("Increase by 10 \(viewModel.servingUnit)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(AppColor.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    /// Both stepper taps animate the mutation so the figures they drive can
    /// roll with `.numericText()` instead of hard-cutting — at ±10g held
    /// down, the unanimated swap read as a flicker.
    private func stepButton(label: String, amount: Double, color: Color) -> some View {
        Button {
            Haptics.light()
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                viewModel.step(by: amount)
            }
        } label: {
            Text(label)
                .font(.system(size: 24))
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressableCompact)
    }

    private func mealChip(_ mealType: MealType) -> some View {
        let isSelected = viewModel.selectedMealType.id == mealType.id
        return Button {
            if viewModel.selectedMealType.id != mealType.id {
                Haptics.selection()
                viewModel.selectedMealType = mealType
            }
        } label: {
            // Solid accent for the selected chip, matching the Log Food meal
            // chips, the FAB and the tab bar. This one used to invert that —
            // soft fill with accent text — so the same choice looked like a
            // different kind of control on two adjacent screens.
            Text(mealType.name.capitalized)
                .appBody(13, weight: .semibold)
                .foregroundStyle(isSelected ? .white : AppColor.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(isSelected ? AppColor.accent : AppColor.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var macroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("\(Int(viewModel.scaledCalories))")
                    .appDisplay(30)
                    .foregroundStyle(AppColor.ink)
                    .contentTransition(.numericText())
                Text("kcal for \(Int(viewModel.quantity))\(viewModel.servingUnit)")
                    .appBody(13)
                    .foregroundStyle(AppColor.secondaryText)
                    .contentTransition(.numericText())
            }
            HStack(spacing: 0) {
                macroColumn("\(Int(viewModel.scaledProtein))g", "Protein", AppColor.accent)
                Divider()
                macroColumn("\(Int(viewModel.scaledCarbs))g", "Carbs", AppColor.carbs)
                Divider()
                macroColumn("\(Int(viewModel.scaledFat))g", "Fat", AppColor.energy)
            }
        }
        .padding(16)
        .background(AppColor.surface)
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppColor.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func macroColumn(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .appBody(15, weight: .bold)
                .foregroundStyle(color)
                .contentTransition(.numericText())
            Text(label).appBody(11).foregroundStyle(AppColor.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }
}
