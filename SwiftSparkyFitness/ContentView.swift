//
//  ContentView.swift
//  SwiftSparkyFitness
//
//  Created by Dheeraj on 17/09/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var authViewModel = AuthViewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch (authViewModel.restoreState, authViewModel.session) {
            case (_, .some(let user)):
                MainTabView(user: user) {
                    Task { await authViewModel.signOut() }
                }
                    .transition(.opacity)
            case (.restoring, _):
                // Frame one of a cold launch used to be the full Login screen,
                // even with a valid session, because the check only started
                // after the first render.
                restoringState
                    .transition(.opacity)
            case (.unreachable, _):
                // A transport failure is not a logout. Showing Login here made
                // a Wi-Fi blip look like being signed out, with no explanation
                // and a disabled button.
                offlineState
                    .transition(.opacity)
            case (.done, .none):
                AuthContainerView(viewModel: authViewModel)
                    .transition(.opacity)
            }
        }
        .task { await authViewModel.restoreSession() }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: authViewModel.session?.email)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: authViewModel.restoreState)
        // Above accessibility3 the layout stops being usable rather than just
        // large — the ring's centre text outgrows the ring and the meal rows
        // lose their calorie column. Individual screens that can take more
        // should raise their own ceiling rather than this being lifted.
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }

    private var restoringState: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColor.background)
    }

    private var offlineState: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(AppColor.accent)
                .frame(width: 60, height: 60)
                .background(AppColor.accentSoft, in: Circle())
                .accessibilityHidden(true)
            Text("Can't reach the server")
                .appDisplay(18)
                .foregroundStyle(AppColor.ink)
            // Naming the host turns the most likely first-run failure — a
            // build pointing at a machine you aren't on — from a mystery into
            // something diagnosable.
            Text("Couldn't connect to \(APIClient.shared.baseURL.host ?? "the server"). Check that it's running and you're on the same network.")
                .appBody(13)
                .foregroundStyle(AppColor.secondaryText)
                .multilineTextAlignment(.center)
            PrimaryButton(title: "Try again") {
                Task { await authViewModel.restoreSession() }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColor.background)
    }
}

#Preview {
    ContentView()
}
