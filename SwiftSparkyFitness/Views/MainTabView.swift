//
//  MainTabView.swift
//  SwiftSparkyFitness
//
//  The authenticated shell.
//
//  WHY THIS IS A REAL TabView NOW
//  ------------------------------
//  It used to be a `switch` over the selected tab inside a VStack, with a
//  hand-rolled bar underneath. That reads fine but it means each screen is
//  *removed from the hierarchy* when you leave it, taking its `@StateObject`
//  with it. Verified: browse Diary to Sep 20, tap Today, tap Diary — you were
//  back on today, with the collapsed sections and the scroll position gone.
//  Re-tapping the active tab also did nothing, where every iOS app scrolls to
//  top.
//
//  `TabView` keeps the screens alive, so all of that comes back for free,
//  along with keyboard traversal and the system's own tab accessibility.
//
//  The design's ringed icons survive the move: each tab uses the `.circle`
//  variant of its glyph, which is the same "stroked circle with a
//  meaning-specific glyph inside" language drawn as one real SF Symbol,
//  rather than a ZStack the tab bar would have to flatten.
//

import SwiftUI

struct MainTabView: View {
    let user: SessionUser
    var onSignOut: () -> Void = {}
    @State private var selection: AppTab = .today

    var body: some View {
        TabView(selection: $selection) {
            Tab(value: AppTab.today) {
                TodayView(user: user)
            } label: {
                Label(AppTab.today.label, systemImage: AppTab.today.symbol)
            }

            Tab(value: AppTab.diary) {
                DiaryView(user: user)
            } label: {
                Label(AppTab.diary.label, systemImage: AppTab.diary.symbol)
            }

            Tab(value: AppTab.progress) {
                ProgressTabView(user: user)
            } label: {
                Label(AppTab.progress.label, systemImage: AppTab.progress.symbol)
            }

            Tab(value: AppTab.settings) {
                SettingsView(user: user, onSignOut: onSignOut)
            } label: {
                Label(AppTab.settings.label, systemImage: AppTab.settings.symbol)
            }
        }
        .tint(AppColor.accent)
    }
}
