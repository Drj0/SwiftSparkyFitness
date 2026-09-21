//
//  FoodEntrySummary+Editing.swift
//  SwiftSparkyFitness
//
//  Diary-only: reconstructs a Food (with its base-serving FoodVariant) from
//  an already-logged entry, so the exact same FoodDetailView/ViewModel
//  Module 2 built for "Log Food" can reopen pre-loaded for editing —
//  no separate edit UI.
//

import Foundation

extension FoodEntrySummary {
    /// `calories`/`protein`/`carbs`/`fat` on the entry are already scaled
    /// for the logged `quantity` (createFoodEntry's math, confirmed live:
    /// 100g of a 50g/200kcal base variant logs as 400kcal) — not the
    /// variant's base per-serving values FoodDetailViewModel scales *from*.
    /// This inverts that scale to recover them. `nil` when the entry is
    /// missing the ids a real edit needs (shouldn't happen for anything the
    /// app itself logged, but a defensive nil is cheaper than a crash).
    var editableFood: Food? {
        guard let foodId, let variantId, let servingSize, servingSize > 0, quantity > 0 else { return nil }
        let scale = quantity / servingSize
        let variant = FoodVariant(
            id: variantId,
            servingSize: servingSize,
            servingUnit: servingUnit ?? unit,
            calories: calories / scale,
            protein: protein.map { $0 / scale },
            carbs: carbs.map { $0 / scale },
            fat: fat.map { $0 / scale }
        )
        return Food(id: foodId, name: foodName, brand: brandName, defaultVariant: variant)
    }
}
