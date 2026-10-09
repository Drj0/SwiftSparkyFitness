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
    @ObservedObject private var cloud = CloudSyncStatus.shared
    @Environment(\.scenePhase) private var scenePhase
    /// A move of the diary made on another device, offered to follow.
    @State private var moveElsewhere: LocalHandoff?
    @State private var isShowingMoveElsewhere = false
    /// Following a move to this device's diary: the copy has to be brought
    /// over first, which can take a while on a long history.
    @State private var deviceMove: Task<Void, Never>?
    @State private var deviceMoveError: String?
    /// First-run setup, opened on its own while there's no goal yet.
    @State private var isOnboarding = false
    /// `.active` also follows `.inactive` alone — Control Center, a Face ID
    /// prompt, a system alert — and each of those used to cost a full sync
    /// (server) or a sweep of every table (iCloud). Only a real return from
    /// the background counts; launch is covered by `.task` and `activate`.
    @State private var wasInBackground = false

    var body: some View {
        TabView(selection: $selection) {
            TodayView(user: user).offlineBanner(serverSync)
                .tabItem { Label(AppTab.today.label, systemImage: AppTab.today.symbol) }
                .tag(AppTab.today)

            ExerciseTabView(user: user).offlineBanner(serverSync)
                .tabItem { Label(AppTab.diary.label, systemImage: AppTab.diary.symbol) }
                .tag(AppTab.diary)

            ProgressTabView(user: user, onOpenToday: { selection = .today }).offlineBanner(serverSync)
                .tabItem { Label(AppTab.progress.label, systemImage: AppTab.progress.symbol) }
                .tag(AppTab.progress)

            SettingsView(user: user, onSignOut: onSignOut).offlineBanner(serverSync)
                .tabItem { Label(AppTab.settings.label, systemImage: AppTab.settings.symbol) }
                .tag(AppTab.settings)
        }
        .tint(AppColor.accent)
        // The system tab bar gives no haptic of its own on a switch; one
        // tick per tab change, the same the week strip gives per day.
        .sensoryFeedback(.selection, trigger: selection)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                guard wasInBackground else { break }
                wasInBackground = false
                if !AppMode.isLocal { serverSync.becameActive() }
                checkOtherDevices()
            case .background:
                wasInBackground = true
                if !AppMode.isLocal { serverSync.resignedActive() }
            default: break
            }
        }
        .task {
            // Launched in the background (an iCloud push): the first time
            // the user opens it is a return, and gets the foreground work.
            if scenePhase == .background { wasInBackground = true }
            checkOtherDevices()
            if !AppMode.isLocal, PendingServerHandoff.isPending { isOfferingHandoff = true }
            await offerOnboardingIfNew()
        }
        // The diary finished arriving from iCloud (or turned out not to be
        // coming): what was put off for it — onboarding, the daily backup,
        // a move made on another device — is decided now, on the real diary.
        .onChange(of: cloud.isAwaitingInitialImport) { _, waiting in
            guard !waiting, AppMode.isLocal else { return }
            checkOtherDevices()
            Task { await offerOnboardingIfNew() }
        }
        .fullScreenCover(isPresented: $isOnboarding) {
            OnboardingView(account: serverSync.account) {
                isOnboarding = false
                NotificationCenter.default.post(name: .referenceDataChanged, object: nil)
            }
        }
        .alert(moveElsewhereTitle, isPresented: $isShowingMoveElsewhere, presenting: moveElsewhere) { handoff in
            if handoff.toMode == AppMode.server.rawValue {
                Button("Use the server") { DiaryHome.followToServer(handoff) }
                Button("Keep using this iPhone", role: .cancel) { DiaryHome.decline(handoff) }
            } else {
                Button("Switch") { followToDevice(handoff) }
                Button("Keep using the server", role: .cancel) { DiaryHome.decline(handoff) }
            }
        } message: { handoff in
            if handoff.toMode == AppMode.server.rawValue {
                Text("On another device, your diary was moved to \(DiaryHome.host(of: handoff)). Use it here too? Anything logged on this iPhone since can be sent to it after you sign in.")
            } else {
                Text("On another device, your diary was moved off \(DiaryHome.host(of: handoff)) to iCloud. Switch this iPhone too? Anything waiting to sync here comes with it.")
            }
        }
        .sheet(isPresented: Binding(get: { deviceMove != nil }, set: { if !$0 { deviceMove?.cancel(); deviceMove = nil } })) {
            VStack(spacing: 16) {
                Text("Moving your diary to this iPhone")
                    .appBody(17, weight: .semibold)
                    .foregroundStyle(AppColor.ink)
                ProgressView().tint(AppColor.accent)
                Text("Keep the app open until it finishes.")
                    .appBody(12)
                    .foregroundStyle(AppColor.placeholder)
                Button("Cancel") { deviceMove?.cancel(); deviceMove = nil }
                    .appBody(15, weight: .semibold)
                    .foregroundStyle(AppColor.accent)
                    .frame(minHeight: 44)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColor.surface)
            .presentationDetents([.height(220)])
            .interactiveDismissDisabled()
        }
        .alert("Couldn't move your diary", isPresented: Binding(get: { deviceMoveError != nil }, set: { if !$0 { deviceMoveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Nothing changed — you're still using the server. \(deviceMoveError ?? "")")
        }
        .sheet(isPresented: $isOfferingHandoff) {
            ServerHandoffSheet(user: user)
                .presentationDetents([.medium, .large])
        }
    }
}

extension MainTabView {
    private var moveElsewhereTitle: String {
        moveElsewhere?.toMode == AppMode.server.rawValue ? "Your diary moved to a server" : "Your diary moved to iCloud"
    }

    private func offerOnboardingIfNew() async {
        // Not over the handoff offer: someone bringing a diary along
        // isn't new.
        guard !isOfferingHandoff, !isOnboarding else { return }
        switch await OnboardingGate.verdict(account: serverSync.account) {
        case .new: break
        case .returning:
            await offerHealthIfReturning()
            return
        // Couldn't tell (server out of reach, say): neither onboarding nor
        // a "welcome back"; both are asked again next time.
        case .unknown: return
        }
        // No slide up over Today: on a first run it's the next screen
        // after the start screen, not a sheet over an empty diary.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { isOnboarding = true }
    }

    /// Once per install, iOS's Health sheet for someone onboarding didn't
    /// ask (back after a reinstall, say): Health is off,
    /// HealthKit has never been asked here (a reinstall drops the old
    /// answer), and this isn't a diary still arriving from iCloud.
    private func offerHealthIfReturning() async {
        let defaults = UserDefaults.standard
        guard !HealthSync.isEnabled, !defaults.bool(forKey: HealthSync.reconnectOfferedKey),
              !OnboardingGate.isHandled(account: serverSync.account),
              !(AppMode.isLocal && cloud.isAwaitingInitialImport),
              await HealthKitService.shared.hasNeverAsked(),
              // Two alerts at once show one and drop the other; this one
              // waits for next time rather than being spent unseen.
              !isShowingMoveElsewhere, moveElsewhere == nil, deviceMoveError == nil else { return }
        defaults.set(true, forKey: HealthSync.reconnectOfferedKey)
        // Straight to iOS's own sheet, which explains itself and is where
        // Health is allowed or not. A custom "Connect / Not now" alert in
        // front of it is what App Review rejects (guideline 5.1.1).
        let outcome = try? await HealthKitService.shared.requestAuthorization()
        HealthSync.isEnabled = outcome == .answered
        NotificationCenter.default.post(name: .referenceDataChanged, object: nil)
    }

    /// What the other devices on this diary have done since this one last
    /// looked: moved it, logged into it after it moved, or (for the iCloud
    /// diary) left copies of the same rows.
    private func checkOtherDevices() {
        if AppMode.isLocal {
            DiaryHome.usesICloudDiary = true
            DuplicateSweep.schedule(after: .zero)
            // The account is checked first: a backup taken just after an
            // Apple ID change would be the new account's diary.
            Task {
                await ICloudIdentity.check()
                // Not a half-arrived diary: today's backup would be the
                // partial one, kept for a day.
                guard !cloud.isAwaitingInitialImport else { return }
                AutoBackup.saveIfDue()
            }
        } else {
            // Someone who has only ever used a server has no iCloud diary to
            // look at, and opening it would start one.
            guard DiaryHome.usesICloudDiary else { return }
            if let account = serverSync.account, DiaryHome.lateEntries(for: account) > 0 {
                PendingServerHandoff.isPending = true
            }
        }
        if let handoff = DiaryHome.moveMadeElsewhere(serverAccount: serverSync.account) {
            moveElsewhere = handoff
            isShowingMoveElsewhere = true
        }
    }

    /// Switches only once the copy is safely in this device's diary; a
    /// failure leaves everything as it was and the offer standing.
    private func followToDevice(_ handoff: LocalHandoff) {
        deviceMove = Task {
            do {
                try await ServerToDeviceMove.run(user: user)
                deviceMove = nil
                DiaryHome.decline(handoff)
                AppMode.current = .local
            } catch is CancellationError {
                deviceMove = nil
            } catch {
                deviceMove = nil
                deviceMoveError = error.localizedDescription
            }
        }
    }
}

private extension View {
    /// Server mode works from this device's copy; this says so while the
    /// server is out of reach, or a sync has failed, rather than blocking
    /// anything. Applied to each tab's own content, not the TabView: an inset
    /// on the TabView isn't passed down, and the banner sat on top of each
    /// screen's title.
    func offlineBanner(_ sync: ServerSync) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            if !AppMode.isLocal, sync.isActive, SyncBanner.shows(sync) {
                SyncBanner(sync: sync)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                // This device's diary still coming down from iCloud.
                ICloudRestoreBanner()
            }
        }
        .animation(.snappy(duration: 0.25), value: SyncBanner.shows(sync))
    }
}

/// "You're offline" without being in the way: one line under the status bar,
/// nothing to dismiss. Everything still works; this only says where changes
/// are waiting. Tapping it tries the server now instead of waiting for the
/// next automatic attempt.
private struct SyncBanner: View {
    @ObservedObject var sync: ServerSync

    static func shows(_ sync: ServerSync) -> Bool {
        if case .failed = sync.status { return true }
        return !sync.isReachable
    }

    /// Only a retry the user asked for shows as one: automatic attempts
    /// pass through `.syncing` too, and the banner shouldn't blink for them.
    @State private var isRetrying = false

    private var text: String {
        let pending = sync.pendingCount
        let waiting = "\(pending) change\(pending == 1 ? "" : "s") waiting to sync"
        if isRetrying { return "Trying your server…" }
        if case .failed = sync.status {
            return pending > 0 ? "Couldn't sync · \(waiting)" : "Couldn't sync · tap to retry"
        }
        return pending > 0 ? "Server offline · \(waiting)" : "Server offline · showing this iPhone's copy"
    }

    var body: some View {
        Button {
            isRetrying = true
            Task {
                await sync.syncNow(timeout: .seconds(15))
                isRetrying = false
            }
        } label: {
            HStack(spacing: 6) {
                if isRetrying {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "icloud.slash")
                        .font(.system(size: 12, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(text)
                    .appBody(12, weight: .semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if !isRetrying {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(AppColor.secondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 28)
            .background(AppColor.surface, in: Capsule())
            .overlay(Capsule().stroke(AppColor.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isRetrying)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
        .accessibilityHint("Tries your server again")
    }
}
