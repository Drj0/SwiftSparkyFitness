//
//  SearchResultStates.swift
//  SparkyFitness
//
//  The "no results" / "can't reach the database" states shared by every
//  search sheet (Log Food, Log Exercise) — pulled out of FoodSearchView
//  (Module 2) once Module 12's exercise search needed the exact same shapes
//  with different copy. `subject` names what's being searched ("food
//  database", "exercise database"); `manualEntryLabel` names the fallback
//  action ("Enter food manually", "Create custom exercise").
//

import SwiftUI

struct NoResultsView: View {
    let query: String
    var subject = "food database"
    var manualEntryLabel = "Enter food manually"
    let onManualEntry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("🔎").font(.system(size: 36))
            Text("No results for \"\(query)\"")
                .appDisplay(18)
                .foregroundStyle(AppColor.ink)
                .multilineTextAlignment(.center)
            Text("We couldn't find a match in the \(subject). You can add it yourself instead.")
                .appBody(13)
                .foregroundStyle(AppColor.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)
            Button(action: onManualEntry) {
                Text(manualEntryLabel)
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

struct SearchNetworkErrorView: View {
    var subject = "food database"
    var manualEntryLabel = "Enter food manually"
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
            Text("Can't reach the \(subject)")
                .appDisplay(18)
                .foregroundStyle(AppColor.ink)
                .multilineTextAlignment(.center)
            Text("Check your connection and try again. You can still add this yourself.")
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
                Text(manualEntryLabel)
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
