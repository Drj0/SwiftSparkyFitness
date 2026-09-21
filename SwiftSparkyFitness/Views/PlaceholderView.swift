//
//  PlaceholderView.swift
//  SwiftSparkyFitness
//
//  Stand-in for tabs not built yet (Diary/Progress/Settings land in later
//  modules) — just enough so the tab shell is navigable end to end now.
//

import SwiftUI

struct PlaceholderView: View {
    let title: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .appDisplay(26)
                .foregroundStyle(AppColor.ink)
            Text("Coming in a later module.")
                .appBody(14)
                .foregroundStyle(AppColor.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColor.background)
    }
}
