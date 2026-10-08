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
    @State private var confirmingDiscard = false
    /// False when the caller closes the whole sheet itself on save (Log
    /// Food): going Back here first slid the search list in under a sheet
    /// already on its way down.
    private let dismissesOnSave: Bool

    init(
        food: Food, mealTypes: [MealType], initialMealType: MealType,
        existingEntryId: String? = nil, initialQuantity: Double? = nil, entryDate: Date = Date(),
        dismissesOnSave: Bool = true,
        onLogged: @escaping () -> Void
    ) {
        self.dismissesOnSave = dismissesOnSave
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
            ) { save() }
            .padding(20)
            .overlay(Rectangle().fill(AppColor.hairline).frame(height: 1), alignment: .top)
        }
        .background(AppColor.surface)
        .discardGuard(isDirty: viewModel.isDirty, isPresented: $confirmingDiscard) { dismiss() }
        .alert("Couldn't log that", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { isPresented in if !isPresented { viewModel.errorMessage = nil } }
        ), actions: {
            Button("OK") { viewModel.errorMessage = nil }
        }, message: {
            Text(viewModel.errorMessage ?? "")
        })
    }

    private func save() {
        Task {
            if await viewModel.save() {
                if dismissesOnSave { dismiss() }
                onLogged()
            }
        }
    }

    // Adding has no top-right action: the full-width button at the bottom is
    // the one way to add, and a second "Add" up here only competed with it.
    // Editing gets a Save in the corner, in Liquid Glass like Goals' Save,
    // that does exactly what "Save Changes" below does; like Goals it stays
    // disabled until something has changed.
    //
    // Header padding drops from 14 to 2 because Back carries a 44pt touch
    // target of its own; the row keeps its measured height.
    private var header: some View {
        HStack {
            Button { if viewModel.isDirty { confirmingDiscard = true } else { dismiss() } } label: {
                Text("‹ Back")
                    .appBody(15)
                    .foregroundStyle(AppColor.accent)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Back")

            Spacer()

            if viewModel.isEditing {
                Button(action: save) {
                    if viewModel.isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save").appBody(15, weight: .semibold)
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .tint(AppColor.accent)
                .disabled(!viewModel.isDirty || viewModel.isSaving)
                .accessibilityLabel("Save")
                .accessibilityValue(viewModel.isSaving ? "In progress" : "")
            }
        }
        // The glass Save is taller than Back's 44pt; a floor of its height
        // keeps the header, and everything under it, the same size in add
        // mode, where there's no Save.
        .frame(minHeight: 46)
        .padding(.horizontal, 20)
        .padding(.vertical, 2)
        .overlay(Rectangle().fill(AppColor.hairline).frame(height: 1), alignment: .bottom)
    }

    private var quantityStepper: some View {
        HStack {
            stepButton(label: "–", amount: -viewModel.stepAmount, color: AppColor.placeholder)
                .accessibilityLabel("Decrease by \(FoodVariant.amountText(viewModel.stepAmount, unit: viewModel.servingUnit))")
            Spacer()
            VStack {
                Text("\(Int(viewModel.quantity))")
                    .appBody(20, weight: .bold)
                    .foregroundStyle(AppColor.ink)
                    .contentTransition(.numericText())
                Text(viewModel.servingUnit).appBody(12).foregroundStyle(AppColor.secondaryText)
            }
            Spacer()
            stepButton(label: "+", amount: viewModel.stepAmount, color: AppColor.accent)
                .accessibilityLabel("Increase by \(FoodVariant.amountText(viewModel.stepAmount, unit: viewModel.servingUnit))")
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
                Text("\(Int(viewModel.scaledCalories.rounded()))")
                    .appDisplay(30)
                    .foregroundStyle(AppColor.ink)
                    .contentTransition(.numericText())
                Text("kcal for \(viewModel.quantityText)")
                    .appBody(13)
                    .foregroundStyle(AppColor.secondaryText)
                    .contentTransition(.numericText())
            }
            HStack(spacing: 0) {
                macroColumn("\(Int(viewModel.scaledProtein))g", "Protein", AppColor.protein)
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

private enum FoodDetailPreview {
    static let meals = [
        MealType(id: "1", name: "breakfast", sortOrder: 10),
        MealType(id: "2", name: "lunch", sortOrder: 20),
        MealType(id: "3", name: "dinner", sortOrder: 30),
    ]
    static let food = Food(
        id: "f", name: "French toast", brand: nil,
        defaultVariant: FoodVariant(id: "v", servingSize: 100, servingUnit: "g", calories: 229, protein: 7.9, carbs: 25, fat: 10)
    )
}

#Preview("Adding") {
    FoodDetailView(food: FoodDetailPreview.food, mealTypes: FoodDetailPreview.meals, initialMealType: FoodDetailPreview.meals[2], onLogged: {})
}

#Preview("Editing") {
    FoodDetailView(food: FoodDetailPreview.food, mealTypes: FoodDetailPreview.meals, initialMealType: FoodDetailPreview.meals[2], existingEntryId: "e", initialQuantity: 150, onLogged: {})
}
