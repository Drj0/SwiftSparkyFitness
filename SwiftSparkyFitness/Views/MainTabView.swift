//
//  MainTabView.swift
//  SwiftSparkyFitness
//
//  The authenticated shell: custom AppTabBar (Today/Diary/Progress/Settings)
//  over the screen for whichever tab is selected.
//

import SwiftUI

struct MainTabView: View {
    let user: SessionUser
    var onSignOut: () -> Void = {}
    @State private var selection: AppTab = .today

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            AppTabBar(selection: $selection)
        }
        .background(AppColor.background)
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .today: TodayView(user: user)
        case .diary: DiaryView(user: user)
        case .progress: PlaceholderView(title: "Progress")
        case .settings: SettingsView(user: user, onSignOut: onSignOut)
        }
    }
}
