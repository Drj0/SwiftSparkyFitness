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
    /// Offered once, right after signing in to a server from this device's
    /// diary. "Not now" leaves a row in Settings to come back to.
    @State private var isOfferingHandoff = false
    @ObservedObject private var serverSync = ServerSync.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $selection) {
            Tab(value: AppTab.today) {
                TodayView(user: user).offlineBanner(serverSync)
            } label: {
                Label(AppTab.today.label, systemImage: AppTab.today.symbol)
            }

            Tab(value: AppTab.diary) {
                ExerciseTabView(user: user).offlineBanner(serverSync)
            } label: {
                Label(AppTab.diary.label, systemImage: AppTab.diary.symbol)
            }

            Tab(value: AppTab.progress) {
                ProgressTabView(user: user).offlineBanner(serverSync)
            } label: {
                Label(AppTab.progress.label, systemImage: AppTab.progress.symbol)
            }

            Tab(value: AppTab.settings) {
                SettingsView(user: user, onSignOut: onSignOut).offlineBanner(serverSync)
            } label: {
                Label(AppTab.settings.label, systemImage: AppTab.settings.symbol)
            }
        }
        .tint(AppColor.accent)
        // The system tab bar gives no haptic of its own on a switch; one
        // tick per tab change, the same the week strip gives per day.
        .sensoryFeedback(.selection, trigger: selection)
        .onChange(of: scenePhase) { _, phase in
            guard !AppMode.isLocal else { return }
            switch phase {
            case .active: serverSync.becameActive()
            case .background: serverSync.resignedActive()
            default: break
            }
        }
        .task {
            if !AppMode.isLocal, PendingServerHandoff.isPending { isOfferingHandoff = true }
        }
        .sheet(isPresented: $isOfferingHandoff) {
            ServerHandoffSheet(user: user)
                .presentationDetents([.medium, .large])
        }
    }
}

private extension View {
    /// Server mode works from this device's copy; this says so while the
    /// server is out of reach, rather than blocking anything. Applied to each
    /// tab's own content, not the TabView: an inset on the TabView isn't
    /// passed down, and the banner sat on top of each screen's title.
    func offlineBanner(_ sync: ServerSync) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            if !AppMode.isLocal, sync.isActive, !sync.isReachable {
                OfflineBanner(pending: sync.pendingCount)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: sync.isReachable)
    }
}

/// "You're offline" without being in the way: one line under the status bar,
/// no button, nothing to dismiss. Everything still works; this only says
/// where changes are waiting.
private struct OfflineBanner: View {
    let pending: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 12, weight: .semibold))
                .accessibilityHidden(true)
            Text(pending > 0
                 ? "Server offline · \(pending) change\(pending == 1 ? "" : "s") will sync when it's back"
                 : "Server offline · showing this iPhone's copy")
                .appBody(12, weight: .semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(AppColor.secondaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(AppColor.surface, in: Capsule())
        .overlay(Capsule().stroke(AppColor.hairline, lineWidth: 1))
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
    }
}
