//
//  SettingsView.swift
//  SwiftSparkyFitness
//
//  Settings: the server address, goals, meals, water containers, units,
//  Apple Health, and signing out.
//
//  This replaced the placeholder tab specifically because the backend URL
//  stopped being a hardcoded constant — without somewhere to type it, a fresh
//  install has no way to reach a server at all.
//

import SwiftUI

struct SettingsView: View {
    let user: SessionUser
    var onSignOut: () -> Void = {}

    @AppStorage(ServerConfig.defaultsKey) private var serverURL = ""
    @AppStorage(AppMode.defaultsKey) private var modeRaw = AppMode.server.rawValue
    @State private var isPresentingServer = false
    @State private var isConfirmingWipe = false
    @State private var wipeError: String?

    private var isLocal: Bool { modeRaw == AppMode.local.rawValue }
    @State private var isPresentingGoals = false
    @State private var isPresentingMeals = false
    @State private var isPresentingWater = false
    @State private var isPresentingUnits = false
    @AppStorage(HealthSync.defaultsKey) private var healthSyncEnabled = false

    private let health: HealthKitReading = HealthKitService.shared
    private var healthAvailable: Bool { health.isAvailable }

    /// Presenting the sheet is all the app can do. HealthKit deliberately
    /// won't say whether reading was allowed, so the toggle records that the
    /// user opted in, not that access was granted.
    private func connectHealth() async {
        try? await health.requestAuthorization()
    }

    private var effective: String { ServerConfig.urlString }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings")
                    .appDisplay(26)
                    .foregroundStyle(AppColor.ink)

                // Local mode has no server and no account, so both of those
                // sections are hidden rather than shown inert — a disabled
                // control still implies it might one day apply here.
                if isLocal {
                    localDataSection
                } else {
                    serverSection
                }

                // Today's goal-not-set card is the other way in, but it
                // disappears the moment a goal exists — without this, a goal
                // could be set once and never changed again.
                section("GOALS") {
                    Text("Daily calorie, macro and water targets. These drive the rings on Today.")
                        .appBody(13)
                        .foregroundStyle(AppColor.secondaryText)

                    Button { isPresentingGoals = true } label: {
                        Text("Edit daily goals")
                            .appBody(15, weight: .semibold)
                            .foregroundStyle(AppColor.accent)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                }

                section("MEALS") {
                    Text("The meals food is logged into. Add your own, or hide any you don't use.")
                        .appBody(13)
                        .foregroundStyle(AppColor.secondaryText)

                    Button { isPresentingMeals = true } label: {
                        Text("Edit meals")
                            .appBody(15, weight: .semibold)
                            .foregroundStyle(AppColor.accent)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                }

                section("WATER") {
                    Text("The container the “+” logs from. Without one it adds \(isLocal ? "the standard" : "the server's default") 250 ml.")
                        .appBody(13)
                        .foregroundStyle(AppColor.secondaryText)

                    Button { isPresentingWater = true } label: {
                        Text("Edit containers")
                            .appBody(15, weight: .semibold)
                            .foregroundStyle(AppColor.accent)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                }

                section("UNITS") {
                    Text("How weights, measurements and water are labelled.")
                        .appBody(13)
                        .foregroundStyle(AppColor.secondaryText)

                    Button { isPresentingUnits = true } label: {
                        Text("Edit units")
                            .appBody(15, weight: .semibold)
                            .foregroundStyle(AppColor.accent)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                }

                section("APPLE HEALTH") {
                    // Who does the taking differs by mode; that the rule is
                    // the same in both is the point worth stating.
                    Text("Counts the active energy Health has recorded towards your daily burn. Your logged workouts still count — whichever total is higher wins, so nothing is counted twice.")
                        .appBody(13)
                        .foregroundStyle(AppColor.secondaryText)

                    if healthAvailable {
                        Toggle(isOn: $healthSyncEnabled) {
                            Text("Use Apple Health")
                                .appBody(15, weight: .semibold)
                                .foregroundStyle(AppColor.ink)
                        }
                        .tint(AppColor.accent)
                        .frame(minHeight: 44)
                        .onChange(of: healthSyncEnabled) { _, isOn in
                            guard isOn else { return }
                            Task { await connectHealth() }
                        }

                        // Health won't report whether a read was granted, so
                        // this can't say "connected" — only that we asked.
                        if healthSyncEnabled {
                            Text("If your burn doesn't change, check SwiftSparkyFitness is allowed to read Active Energy in Health › Sharing › Apps.")
                                .appBody(12)
                                .foregroundStyle(AppColor.placeholder)
                        }
                    } else {
                        Text("Health isn't available on this device.")
                            .appBody(13)
                            .foregroundStyle(AppColor.placeholder)
                    }
                }

                if !isLocal {
                    section("ACCOUNT") {
                        row("Signed in as", user.email)
                        Button(action: onSignOut) {
                            Text("Sign out")
                                .appBody(15, weight: .semibold)
                                .foregroundStyle(AppColor.destructive)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)
                    }
                }

                section("ABOUT") {
                    row("Version", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                }
            }
            .padding(AppSpacing.screenPad)
            .padding(.bottom, 24)
        }
        .background(AppColor.background)
        .sheet(isPresented: $isPresentingServer) {
            // The day screens cache data belonging to whichever server it came
            // from, so a new address has to drop it. If the new server doesn't
            // know this session, the reload's 401 carries the app back to login
            // through the global handler rather than needing anything here.
            ServerAddressSheet {
                NotificationCenter.default.post(name: .referenceDataChanged, object: nil)
            }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isPresentingGoals) {
            SetGoalsView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isPresentingMeals) {
            MealCategoriesView {
                NotificationCenter.default.post(name: .referenceDataChanged, object: nil)
            }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isPresentingWater) {
            WaterContainersView {
                NotificationCenter.default.post(name: .referenceDataChanged, object: nil)
            }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isPresentingUnits) {
            UnitPreferencesView {
                NotificationCenter.default.post(name: .referenceDataChanged, object: nil)
            }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        // An alert rather than a confirmation dialog, and that's deliberate:
        // in local mode this is the only irreversible control in the app and
        // there is no server copy behind it, so the way out has to be a real
        // button. A confirmation dialog renders as a popover in some
        // presentations and drops its cancel action, leaving tapping outside
        // as the only escape — discoverable with a finger, not with VoiceOver
        // or Switch Control. An alert always draws both.
        .alert("Delete all local data?", isPresented: $isConfirmingWipe) {
            Button("Cancel", role: .cancel) {}
            Button("Delete everything", role: .destructive, action: wipeLocalData)
        } message: {
            // Says settings too, because the wipe does reset them: naming only
            // the entries and then silently returning units to kg is the kind
            // of small dishonesty that makes the rest of the warning suspect.
            Text("Every food, exercise, water, weight and measurement entry on this iPhone is erased, and your meal categories and unit settings go back to their defaults. This can't be undone.")
        }
    }

    /// Erases the store and tells the day screens to re-read, so Today and
    /// Diary don't keep rendering rows that no longer exist.
    private func wipeLocalData() {
        do {
            try LocalStore.shared.deleteEverything()
            wipeError = nil
            Haptics.success()
            NotificationCenter.default.post(name: .referenceDataChanged, object: nil)
        } catch {
            // Reported rather than swallowed: a wipe that silently half-ran
            // would leave the user believing their data is gone when it isn't.
            wipeError = "Couldn't delete everything — some data may remain. \(error.localizedDescription)"
            Haptics.error()
        }
    }

    /// The field itself lives in ServerAddressSheet, which the offline screen
    /// also presents. Two copies meant two validation paths, and this was the
    /// weaker: it accepted any string `URL(string:)` would parse, host or not.
    private var serverSection: some View {
        section("SERVER") {
            Text("SwiftSparkyFitness talks to a SparkyFitness server you run yourself.")
                .appBody(13)
                .foregroundStyle(AppColor.secondaryText)

            // Read so that saving in the sheet re-renders this row. The value
            // shown is still ServerConfig's, since a SERVER_URL in the
            // environment outranks whatever is stored.
            let _ = serverURL
            Text(effective)
                .appBody(14, weight: .semibold)
                .foregroundStyle(AppColor.ink)

            if ServerConfig.isUnconfigured {
                Text("No server set yet — using the placeholder, so nothing will load.")
                    .appBody(12)
                    .foregroundStyle(AppColor.destructive)
            }

            Button { isPresentingServer = true } label: {
                Text("Edit server address")
                    .appBody(15, weight: .semibold)
                    .foregroundStyle(AppColor.accent)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)

            Button { switchMode(to: .local) } label: {
                Text("Use this device only instead")
                    .appBody(15, weight: .semibold)
                    .foregroundStyle(AppColor.accent)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
        }
    }

    /// Local mode's replacement for SERVER and ACCOUNT.
    ///
    /// The warning is not decoration. With no server there is no copy of this
    /// data anywhere else, so deleting the app deletes the diary — and that is
    /// the one consequence a person choosing this mode is least likely to have
    /// thought through.
    private var localDataSection: some View {
        section("THIS DEVICE") {
            Text("Everything you log is stored on this iPhone only. There's no account and nothing leaves the device.")
                .appBody(13)
                .foregroundStyle(AppColor.secondaryText)

            Text("Nothing is backed up. Deleting the app, or erasing this iPhone, deletes your diary with it.")
                .appBody(12)
                .foregroundStyle(AppColor.destructive)

            // Switching is allowed and deliberately non-destructive: the local
            // rows stay on disk and come back if the user returns. Syncing the
            // two together is a separate piece of work that doesn't exist yet,
            // so the copy promises separation, not merging.
            Button { switchMode(to: .server) } label: {
                Text("Connect to a server instead")
                    .appBody(15, weight: .semibold)
                    .foregroundStyle(AppColor.accent)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)

            Text("Your on-device data stays here and isn't sent to the server. It reappears if you switch back.")
                .appBody(12)
                .foregroundStyle(AppColor.placeholder)

            Button(role: .destructive) { isConfirmingWipe = true } label: {
                Text("Delete all local data")
                    .appBody(15, weight: .semibold)
                    .foregroundStyle(AppColor.destructive)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)

            if let wipeError {
                Text(wipeError)
                    .appBody(12)
                    .foregroundStyle(AppColor.destructive)
            }
        }
    }

    private func switchMode(to mode: AppMode) {
        AppMode.current = mode
        Haptics.success()
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .appBody(12, weight: .semibold)
                .foregroundStyle(AppColor.secondaryText)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppColor.surface)
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppColor.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).appBody(14).foregroundStyle(AppColor.secondaryText)
            Spacer()
            Text(value).appBody(14, weight: .semibold).foregroundStyle(AppColor.ink)
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .combine)
    }
}
