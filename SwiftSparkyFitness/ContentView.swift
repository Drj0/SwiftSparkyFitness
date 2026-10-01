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
    @State private var isEditingServer = false
    /// "Try again" keeps the error screen up with a busy button rather than
    /// swapping to the connecting screen: a refusal comes back in
    /// milliseconds, and the swap there and back read as nothing happening.
    @State private var isRetrying = false
    /// Empty until a mode is chosen, which is what puts the picker on screen.
    /// Read as the raw string rather than `AppMode.current` so the view
    /// re-renders when the choice is made.
    @AppStorage(AppMode.defaultsKey) private var modeRaw = ""

    var body: some View {
        Group {
            if modeRaw.isEmpty {
                ModeChoiceView { await authViewModel.restoreSession() }
                    .transition(.opacity)
            } else {
                // Keyed on the mode so switching it rebuilds the tab tree.
                // Every screen's view model resolves its client once in its
                // own init, and `MainTabView` keeps the same view identity
                // across a switch (the session is merely replaced, not
                // removed), so without this the tabs would keep talking to
                // the mode the app was launched in.
                signedInOrOut.id(modeRaw)
            }
        }
        .sheet(isPresented: $isEditingServer) {
            ServerAddressSheet { Task { await authViewModel.restoreSession() } }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        // Gated on a mode being chosen: before that there is nothing to
        // restore, and in server mode this would fire a request at whatever
        // placeholder address is configured.
        .task { if !modeRaw.isEmpty { await authViewModel.restoreSession() } }
        // Switching mode in Settings swaps which client every view model
        // resolves, so the session has to be re-established against the new
        // one: local mode hands back its synthetic user, server mode falls to
        // login if there's no cookie. Doing it here keeps Settings from
        // needing a route back up to the auth state.
        //
        // Not on the way back to the start screen, though: with no mode the
        // client resolves to the server one, and a restore then would send a
        // request to a server the user just stepped away from.
        .onChange(of: modeRaw) { _, newValue in
            guard !newValue.isEmpty else { return }
            Task { await authViewModel.restoreSession() }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: authViewModel.session?.email)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: authViewModel.restoreState)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: modeRaw)
        // Above accessibility3 the layout stops being usable rather than just
        // large — the ring's centre text outgrows the ring and the meal rows
        // lose their calorie column. Individual screens that can take more
        // should raise their own ceiling rather than this being lifted.
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }

    @ViewBuilder
    private var signedInOrOut: some View {
        Group {
            switch (authViewModel.restoreState, authViewModel.session) {
            case (_, .some(let user)):
                MainTabView(user: user) {
                    Task { await authViewModel.signOut() }
                }
                    .transition(.opacity)
            case (.restoring, _) where isRetrying:
                offlineState
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
    }

    /// Local mode answers in a frame or two, so it keeps the bare spinner;
    /// anything more would only flash. A server can take up to the request
    /// timeout, and a spinner with no words and no way out for that long
    /// reads as a hang — so after a moment it says what it's waiting on and
    /// offers Back.
    @ViewBuilder
    private var restoringState: some View {
        if AppMode.isLocal {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppColor.background)
        } else {
            ConnectingState(host: serverHost) { isEditingServer = true }
        }
    }

    private var offlineState: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            Image(systemName: "wifi.slash")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(AppColor.accent)
                .frame(width: 64, height: 64)
                .background(AppColor.accentSoft, in: Circle())
                .accessibilityHidden(true)

            Text("Can't connect to the server")
                .appDisplay(24)
                .foregroundStyle(AppColor.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 20)

            // Naming the host turns the most likely failure — an address
            // typed wrong, or a server that's off — from a mystery into
            // something diagnosable. The second sentence is the way through
            // when it can't be fixed from here.
            Text("Sparky couldn't reach \(serverHost). Check that the server is running and this iPhone can reach it — or use Sparky on this iPhone for now.")
                .appBody(14)
                .foregroundStyle(AppColor.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            VStack(spacing: 10) {
                PrimaryButton(title: "Try again", isLoading: isRetrying, action: retry)

                // The way through when the server can't be fixed from this
                // phone. Sparky works fully without one, so being offline
                // from a server must never mean being locked out of the app.
                Button {
                    AppMode.leaveServer(for: .local)
                } label: {
                    Text("Use on this iPhone instead")
                        .appBody(16, weight: .semibold)
                        .foregroundStyle(AppColor.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.md))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.md)
                                .stroke(AppColor.hairline, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressableLarge)

                // No connection means no sign-in, no tab bar and no
                // Settings, so the one field that fixes a typo has to be
                // reachable from here.
                Button("Change server address") { isEditingServer = true }
                    .appBody(14, weight: .semibold)
                    .foregroundStyle(AppColor.accent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .padding(.top, 28)

            Text("You can connect to a server again anytime in Settings.")
                .appBody(12)
                .foregroundStyle(AppColor.placeholder)
                .multilineTextAlignment(.center)
                .padding(.top, 4)

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColor.background)
        .safeAreaInset(edge: .top, spacing: 0) {
            ServerScreenBar(onBack: { AppMode.leaveServer(for: nil) }, onEditServer: { isEditingServer = true })
        }
    }

    /// Long enough for the spinner to register, and a buzz if it failed
    /// again, so an instant refusal still reads as a real attempt.
    private func retry() {
        guard !isRetrying else { return }
        isRetrying = true
        Task {
            let started = ContinuousClock.now
            await authViewModel.restoreSession()
            let elapsed = ContinuousClock.now - started
            if elapsed < .milliseconds(600) { try? await Task.sleep(for: .milliseconds(600) - elapsed) }
            isRetrying = false
            if authViewModel.restoreState == .unreachable { Haptics.error() }
        }
    }

    /// "192.168.1.20" — the part of the address a person recognises.
    private var serverHost: String {
        ServerConfig.isUnconfigured ? "the server" : (ServerConfig.url.host ?? "the server")
    }
}

/// The server-mode launch check while it is still waiting. The spinner shows
/// at once, as before; the words and the bar only after a moment, so a
/// server that answers quickly — the usual case — never flashes them.
private struct ConnectingState: View {
    let host: String
    var onEditServer: () -> Void

    @State private var isSlow = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            if isSlow {
                Text("Connecting to \(host)…")
                    .appBody(14)
                    .foregroundStyle(AppColor.secondaryText)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColor.background)
        .safeAreaInset(edge: .top, spacing: 0) {
            if isSlow {
                ServerScreenBar(onBack: { AppMode.leaveServer(for: nil) }, onEditServer: onEditServer)
                    .transition(.opacity)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { isSlow = true }
        }
    }
}

#Preview {
    ContentView()
}
