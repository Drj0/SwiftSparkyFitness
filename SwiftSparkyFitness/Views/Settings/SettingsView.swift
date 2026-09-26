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
import UIKit

struct SettingsView: View {
    let user: SessionUser
    var onSignOut: () -> Void = {}

    @AppStorage(ServerConfig.defaultsKey) private var serverURL = ""
    @AppStorage(AppMode.defaultsKey) private var modeRaw = AppMode.server.rawValue
    @State private var isPresentingServer = false
    @State private var isConfirmingWipe = false
    @State private var wipeError: String?
    @ObservedObject private var sync = CloudSyncStatus.shared
    @Environment(\.openURL) private var openURL

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

                // ───────────────────────────────────────────────────────
                // Grouped by what an item is to the user, not by the module
                // that added it, and each group is a list of rows rather
                // than a stack of paragraphs: a row names the thing and
                // opens it, and the explaining happens inside. See
                // PROGRESS.md for where new items belong.
                // ───────────────────────────────────────────────────────

                // First, because in local mode it is the most consequential
                // thing on the screen: whether there is a second copy of
                // your diary anywhere.
                if isLocal {
                    localDataSection
                } else {
                    serverSection
                }

                // Server mode only. Local mode has no account, and showing
                // one inert would imply it might one day apply here.
                if !isLocal {
                    section("ACCOUNT") {
                        row("Signed in as", user.email)
                    }
                }

                // Both of these answer "how is the app set up for me".
                section("GOALS & UNITS") {
                    // Today's goal-not-set card is the other way in, but it
                    // disappears the moment a goal exists — without this, a
                    // goal could be set once and never changed again.
                    linkRow("Daily goals", "Calories, macros and water") { isPresentingGoals = true }
                    rowDivider
                    linkRow("Units", "How weights and water are labelled") { isPresentingUnits = true }
                }

                // Both of these shape what logging a thing does.
                section("LOGGING") {
                    linkRow("Meals", "The meals food is logged into") { isPresentingMeals = true }
                    rowDivider
                    linkRow("Water containers", "What one tap of “+” logs") { isPresentingWater = true }
                }

                // Its own section rather than folded into LOGGING: this one
                // is a connection to another app with its own permission
                // state, not a preference about this one.
                //
                // Deliberately just the switch and one line. The paragraph
                // that used to sit here explained the max(Health, logged)
                // rule in full, which is a thing to know *if* you turn this
                // on — not a wall to read before deciding to.
                section("APPLE HEALTH") {
                    if healthAvailable {
                        Toggle(isOn: $healthSyncEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Sync Apple Health")
                                    .appBody(15, weight: .semibold)
                                    .foregroundStyle(AppColor.ink)
                                Text("Counts active energy towards your daily burn.")
                                    .appBody(12)
                                    .foregroundStyle(AppColor.placeholder)
                            }
                        }
                        .tint(AppColor.accent)
                        .frame(minHeight: 44)
                        .onChange(of: healthSyncEnabled) { _, isOn in
                            guard isOn else { return }
                            Task { await connectHealth() }
                        }

                        // Only once it's on, because only then can it be
                        // wrong in this particular way. Health won't report
                        // whether a read was granted, so this can't say
                        // "connected" — only that we asked.
                        if healthSyncEnabled {
                            Text("Logged workouts still count — whichever total is higher wins. If your burn doesn't change, check SwiftSparkyFitness is allowed to read Active Energy in Health › Sharing › Apps.")
                                .appBody(12)
                                .foregroundStyle(AppColor.placeholder)
                        }
                    } else {
                        Text("Health isn't available on this device.")
                            .appBody(13)
                            .foregroundStyle(AppColor.placeholder)
                    }
                }

                section("ABOUT") {
                    row("Version", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                }

                destructiveActions
            }
            .padding(AppSpacing.screenPad)
            .padding(.bottom, 24)
        }
        .background(AppColor.background)
        // Only in local mode: in server mode the local store isn't the
        // user's data at all, so its sync state would be meaningless.
        .task { if isLocal { await sync.refreshAccountStatus() } }
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
        section("YOUR DATA") {
            // Read so that saving in the sheet re-renders this row. The value
            // shown is still ServerConfig's, since a SERVER_URL in the
            // environment outranks whatever is stored.
            let _ = serverURL

            // The field itself lives in ServerAddressSheet, which the offline
            // screen also presents. Two copies meant two validation paths,
            // and this was the weaker: it accepted any string URL(string:)
            // would parse, host or not.
            linkRow("Server", effective) { isPresentingServer = true }

            if ServerConfig.isUnconfigured {
                Text("No server set yet — using the placeholder, so nothing will load.")
                    .appBody(12)
                    .foregroundStyle(AppColor.destructive)
            }

            rowDivider
            actionRow("Use this device only instead") { switchMode(to: .local) }
        }
    }

    /// Local mode's replacement for SERVER and ACCOUNT.
    ///
    /// The warning is not decoration. With no server there is no copy of this
    /// data anywhere else, so deleting the app deletes the diary — and that is
    /// the one consequence a person choosing this mode is least likely to have
    /// thought through.
    private var localDataSection: some View {
        section("YOUR DATA") {
            Text("Everything you log is stored on this iPhone only. There's no account and nothing leaves the device.")
                .appBody(13)
                .foregroundStyle(AppColor.secondaryText)

            // The warning is conditional, and that is the point of Module
            // 11: with iCloud syncing this is no longer a single copy, and
            // saying otherwise would be untrue. When syncing isn't
            // happening the original warning stands unchanged, because
            // then it is still exactly true.
            if sync.state.backsUpTheDiary {
                Text("Backed up to iCloud, and shared with your other devices signed into the same account.")
                    .appBody(12)
                    .foregroundStyle(AppColor.secondaryText)
            } else {
                Text("Nothing is backed up. Deleting the app, or erasing this iPhone, deletes your diary with it.")
                    .appBody(12)
                    .foregroundStyle(AppColor.destructive)
            }

            rowDivider
            iCloudStatus
            rowDivider

            actionRow("Connect to a server instead") { switchMode(to: .server) }

            Text("Your on-device data stays here and isn't sent to the server. It reappears if you switch back.")
                .appBody(12)
                .foregroundStyle(AppColor.placeholder)

            if let wipeError {
                Text(wipeError)
                    .appBody(12)
                    .foregroundStyle(AppColor.destructive)
            }
        }
    }

    /// The one-way doors, separated from everything above and last on the
    /// screen — the iOS convention, and the reason for it: these sit at the
    /// end of a scroll rather than next to the control someone came here to
    /// tap. Signing out was mid-list in ACCOUNT and the wipe was near the
    /// top of THIS DEVICE, both a thumb-slip from something harmless.
    @ViewBuilder
    private var destructiveActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle()
                .fill(AppColor.hairline)
                .frame(height: 1)
                .accessibilityHidden(true)

            if isLocal {
                Button(role: .destructive) { isConfirmingWipe = true } label: {
                    Text("Delete all local data")
                        .appBody(15, weight: .semibold)
                        .foregroundStyle(AppColor.destructive)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
            } else {
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
        .padding(.top, 4)
    }

    /// iCloud's state, stated plainly. Not a toggle: syncing is a property
    /// of the account and the device, not a preference this app owns, and a
    /// switch here would imply the app can turn iCloud on. It can't.
    @ViewBuilder
    private var iCloudStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("iCloud")
                    .appBody(15, weight: .semibold)
                    .foregroundStyle(AppColor.ink)
                Spacer(minLength: 8)
                Text(sync.state.title)
                    .appBody(14)
                    .foregroundStyle(sync.state.isProblem ? AppColor.destructive : AppColor.secondaryText)
            }
            Text(sync.state.detail())
                .appBody(12)
                .foregroundStyle(AppColor.placeholder)
                .fixedSize(horizontal: false, vertical: true)

            if sync.state.offersSystemSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                Button { openURL(url) } label: {
                    Text("Open iPhone Settings")
                        .appBody(15, weight: .semibold)
                        .foregroundStyle(AppColor.accent)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(.top, 4)
        // One element: VoiceOver reads the state and what it means together,
        // rather than "iCloud", "Not signed in" as two loose strings.
        .accessibilityElement(children: .combine)
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

    /// A row that opens something. The chevron is the promise that there
    /// is more behind it, which is what lets the subtitle stay to one line
    /// — the explaining belongs on the screen it opens, not in front of it.
    private func linkRow(
        _ title: String,
        _ subtitle: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .appBody(15, weight: .semibold)
                        .foregroundStyle(AppColor.ink)
                    if let subtitle {
                        Text(subtitle)
                            .appBody(12)
                            .foregroundStyle(AppColor.placeholder)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColor.placeholder)
                    // Decoration: the Button already announces itself, and
                    // VoiceOver saying "chevron right" after every row is
                    // noise.
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        // Title and subtitle read as one thing rather than two stops.
        .accessibilityElement(children: .combine)
    }

    /// A row that does something here rather than opening a screen, so it
    /// has no chevron — the difference is worth keeping visible.
    private func actionRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .appBody(15, weight: .semibold)
                .foregroundStyle(AppColor.accent)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    /// Separates rows inside one section, so a group of them reads as a
    /// list rather than as a run-on stack.
    private var rowDivider: some View {
        Rectangle()
            .fill(AppColor.hairline)
            .frame(height: 1)
            .accessibilityHidden(true)
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

// Local mode, which is the arrangement with the most in it: the iCloud row
// and the wipe only exist here.
#Preview("Settings — local mode") {
    SettingsView(user: SessionUser(email: "On this device", name: nil, createdAt: Date()))
        .onAppear { UserDefaults.standard.set(AppMode.local.rawValue, forKey: AppMode.defaultsKey) }
}

#Preview("Settings — server mode") {
    SettingsView(user: SessionUser(email: "you@example.com", name: nil, createdAt: Date()))
        .onAppear { UserDefaults.standard.set(AppMode.server.rawValue, forKey: AppMode.defaultsKey) }
}
