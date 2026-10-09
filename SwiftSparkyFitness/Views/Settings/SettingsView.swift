//
//  SettingsView.swift
//  SwiftSparkyFitness
//
//  Settings: where the data lives, goals, meals, water containers, units,
//  Apple Health, and the one-way doors.
//
//  WHY THIS IS A REAL LIST NOW
//  ---------------------------
//  It used to be a `ScrollView` of hand-built cards: a custom section box, a
//  custom row, a hand-drawn hairline between rows, a hand-drawn chevron, and
//  a `Text` for the screen title that scrolled away with the content. It read
//  fine in a screenshot and was wrong in four ways that only show up in use:
//
//    1. **Sub-screens opened as sheets.** Meals, Units and Water containers
//       are destinations in a hierarchy, not modal tasks — none of them has
//       anything to commit, which is why each one's "Done" button only
//       dismissed. Presenting a destination modally costs the back-swipe, the
//       title that says where you are, and the sense that there is a way back
//       up. They push now. The two screens that genuinely *are* forms with a
//       Cancel and a Save — the server address and the daily goals — stay
//       sheets, which is the distinction a sheet is actually for.
//    2. **No navigation bar**, so no large title, no collapse on scroll, and
//       nothing at the top of a pushed screen to name it.
//    3. **Every row was a paragraph with a link under it.** Section headers
//       sat *inside* the card, so each group opened with a label that looked
//       like a row.
//    4. **No icons**, which is what makes a settings screen scannable rather
//       than read line by line.
//
//  A `List` gives 1–3 for free, plus the separator insets, the press
//  highlight, the keyboard traversal and the Dynamic Type behaviour the
//  hand-rolled rows each had to reimplement. It's themed rather than stock —
//  hidden scroll background, the app's own surface behind each row — so it
//  still belongs to this app and not to Settings.app.
//
//  WHERE NEW ITEMS BELONG
//  ----------------------
//  Grouped by what a thing is to the user, not by the module that added it:
//
//    YOUR DATA   — where the diary lives and whether it's safe
//    ACCOUNT     — the identity behind the data (server mode only)
//    GOALS & UNITS — how the app is set up for me
//    LOGGING     — what logging something does
//    APPLE HEALTH — a connection to another app with its own permissions
//    BACKUP      — the export file; occasional, so below the daily things
//    ABOUT       — information, not a control
//    (unheaded)  — irreversible
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    let user: SessionUser
    var onSignOut: () -> Void = {}

    @AppStorage(ServerConfig.defaultsKey) private var serverURL = ""
    @AppStorage(AppMode.defaultsKey) private var modeRaw = AppMode.server.rawValue
    @AppStorage(HealthSync.defaultsKey) private var healthSyncEnabled = false
    @AppStorage(AppDisplayMode.defaultsKey) private var displayModeRaw = AppDisplayMode.system.rawValue
    @AppStorage(AppDisplayMode.experimentalDarkKey) private var experimentalDark = false

    @State private var isPresentingServer = false
    @State private var isPresentingConnect = false
    @State private var isConfirmingWipe = false
    @State private var isConfirmingSignOut = false
    @State private var wipeError: String?
    /// Collapsed by default. See `localDataSection`.
    @State private var isShowingDataDetail = false
    @State private var healthRequest: HealthRequestState = .idle
    /// Not `@AppStorage`: its default depends on a legacy key. See HealthSync.
    @State private var importsWorkouts = HealthSync.importsWorkouts
    /// Switching to this device only asks first: copy the server's diary
    /// over, or start with an empty one.
    @State private var isChoosingLocalData = false
    @State private var localHasEntries = false
    @State private var importProgress: ServerPull.Progress?
    @State private var importTask: Task<Void, Never>?
    @State private var importError: String?
    /// The diary file: exporting writes one, restoring merges one in.
    @State private var exportDocument: DiaryArchiveDocument?
    @State private var isExportingArchive = false
    @State private var isRestoringArchive = false
    @State private var archiveNotice: String?
    @State private var archiveNoticeIsError = false
    /// The notice answers the backup-restore row at the top (YOUR DATA), so
    /// it shows there, not in BACKUP several sections below.
    @State private var archiveNoticeIsNearTop = false
    @State private var lastExportedAt = DiaryExportRecord.lastExportedAt
    @AppStorage(PendingServerHandoff.defaultsKey) private var isHandoffPending = false
    @AppStorage(ICloudIdentity.changedAtKey) private var iCloudAccountChangedAtRaw: Double = 0
    @State private var isPresentingHandoff = false

    @ObservedObject private var sync = CloudSyncStatus.shared
    @ObservedObject private var serverSync = ServerSync.shared
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Two lines of `appBody(12)`, which is what the Health footer is held to
    /// as a minimum. See `healthSection`.
    @ScaledMetric(relativeTo: .caption) private var healthFooterFloor: CGFloat = 32

    private let health: HealthKitReading = HealthKitService.shared

    private var isLocal: Bool { modeRaw == AppMode.local.rawValue }
    private var healthAvailable: Bool { health.isAvailable }
    private var effective: String { ServerConfig.urlString }

    var body: some View {
        NavigationStack {
            List {
                // First, because in local mode it is the most consequential
                // thing on the screen: whether a second copy of your diary
                // exists anywhere.
                // Server mode leads with who is signed in. Local mode has no
                // account, and showing one inert would imply it might one day
                // apply here.
                if isLocal {
                    localDataSection
                } else {
                    accountSection
                    serverSection
                }

                goalsSection
                loggingSection
                healthSection
                backupSection
                if AppDisplayMode.isExperimentAvailable { experimentalSection }
                aboutSection
                oneWayDoors
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(AppColor.background)
            .navigationTitle("Settings")
        }
        // Applied here, not (only) at the app root: an `.onChange` on
        // `SwiftSparkyFitnessApp`'s `@AppStorage` turned out not to reliably
        // refire on every change — verified live, switching Dark -> System
        // updated the stored value but the window never got told. This view
        // is where the value actually changes, so it's also where applying
        // it is reliable.
        .onChange(of: displayModeRaw) { _, _ in applyDisplayMode() }
        .onChange(of: experimentalDark) { _, _ in applyDisplayMode() }
        // Only in local mode: in server mode the local store isn't the user's
        // data at all, so its sync state would be meaningless.
        .task { if isLocal { await sync.refreshAccountStatus() } }
        .sheet(isPresented: $isPresentingServer) {
            // The day screens cache data belonging to whichever server it came
            // from, so a new address has to drop it. If the new server doesn't
            // know this session, the reload's 401 carries the app back to login
            // through the global handler rather than needing anything here.
            ServerAddressSheet {
                NotificationCenter.default.post(name: .referenceDataChanged, object: nil)
            }
            .fittedDetent()
            .presentationDragIndicator(.visible)
        }
        // Switching to server mode asks for the address first, rather than
        // switching and landing the user on a can't-reach-the-server screen to
        // work out why. The field arrives pre-filled with whatever address was
        // used last, so for most people this is confirm-and-go — but it is
        // still a stop, because "I want to change server" and "I want to go
        // back to my server" are the same tap otherwise.
        .sheet(isPresented: $isPresentingConnect) {
            ServerAddressSheet(
                title: "Connect SparkyFitness Server",
                saveTitle: "Connect",
                note: "After you sign in, you can send this iPhone's diary to the server. This iPhone keeps its copy either way."
            ) {
                // The send needs a signed-in session, which the login screen
                // provides after this switch; MainTabView offers it then.
                PendingServerHandoff.isPending = LocalStore.shared.hasDiaryEntries()
                switchMode(to: .server)
            }
            .fittedDetent()
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
            // Always offered: even a synced diary can hold entries from the
            // last few moments that iCloud hasn't taken yet, and a file is
            // the one copy that can't be behind.
            Button("Export first", action: exportDiary)
            Button("Cancel", role: .cancel) {}
            Button("Delete from this iPhone", role: .destructive, action: wipeLocalData)
        } message: {
            Text(wipeMessage)
        }
        .fileExporter(
            isPresented: $isExportingArchive,
            document: exportDocument,
            contentType: .json,
            defaultFilename: DiaryArchiveDocument.defaultFilename()
        ) { result in
            exportDocument = nil
            switch result {
            case .success:
                let now = Date()
                DiaryExportRecord.lastExportedAt = now
                lastExportedAt = now
                archiveNotice = nil
                Haptics.success()
            case .failure(let error):
                showArchiveNotice("Couldn't save the export. \(error.localizedDescription)", isError: true)
            }
        }
        .sheet(isPresented: $isPresentingHandoff) {
            ServerHandoffSheet(user: user)
                .presentationDetents([.medium, .large])
        }
        .fileImporter(isPresented: $isRestoringArchive, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): restoreDiary(from: url)
            case .failure(let error): showArchiveNotice("Couldn't open that file. \(error.localizedDescription)", isError: true)
            }
        }
        // An alert for the same reason as the wipe below: every choice here
        // has to be a real button, Cancel included.
        .alert("Bring your diary to this iPhone?", isPresented: $isChoosingLocalData) {
            Button("Copy my data") { startImport() }
            Button("Start fresh", role: localHasEntries ? .destructive : nil) { startFresh() }
            if localHasEntries {
                Button("Keep this iPhone's diary") { switchMode(to: .local) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if localHasEntries {
                Text("Copy your foods, exercise, water, weight, measurements and goals from the server, or start with an empty diary. This iPhone already has a diary of its own: copying adds the server's to it without duplicating anything already here; starting fresh replaces it\(startFreshReach). The server keeps its copy either way.\(offlineCopyNote)")
            } else {
                Text("Copy your foods, exercise, water, weight, measurements and goals from the server, or start with an empty diary. The server keeps its copy either way.\(offlineCopyNote)")
            }
        }
        .sheet(isPresented: Binding(
            get: { importProgress != nil || importError != nil },
            set: { if !$0 { cancelImport() } }
        )) {
            ImportProgressSheet(progress: importProgress, error: importError, onRetry: startImport, onCancel: cancelImport)
                .presentationDetents([.height(260)])
                .interactiveDismissDisabled(importError == nil)
        }
        .alert("Sign out?", isPresented: $isConfirmingSignOut) {
            if serverSync.pendingCount > 0 {
                Button("Export first", action: exportDiary)
            }
            Button("Cancel", role: .cancel) {}
            Button("Sign out", role: .destructive, action: onSignOut)
        } message: {
            // Nothing is lost — it all lives on the server — and saying so is
            // the point: without it this reads as destructive as the wipe.
            // Unless it doesn't all live there yet: then that comes first.
            if serverSync.pendingCount > 0 {
                Text("\(serverSync.pendingCount) change\(serverSync.pendingCount == 1 ? "" : "s") on this iPhone haven't reached the server yet. Signing out removes this iPhone's copy, and them with it.")
            } else {
                Text("Your diary stays on the server. You'll need your email and password to sign back in.")
            }
        }
    }

    // MARK: - Your data

    /// The field itself lives in `ServerAddressSheet`, which the offline screen
    /// also presents. Two copies meant two validation paths, and this was the
    /// weaker: it accepted any string `URL(string:)` would parse, host or not.
    private var serverSection: some View {
        Section {
            // Read so that saving in the sheet re-renders this row. The value
            // shown is still ServerConfig's, since a SERVER_URL in the
            // environment outranks whatever is stored.
            let _ = serverURL

            Button { isPresentingServer = true } label: {
                SettingsRow(
                    icon: "externaldrive.connected.to.line.below",
                    tint: AppColor.water,
                    title: "Server",
                    value: effective,
                    opensDetail: true
                )
            }
            .buttonStyle(.plain)

            Button { Task { await serverSync.syncNow() } } label: {
                SettingsRow(
                    icon: "arrow.triangle.2.circlepath",
                    tint: serverSync.isReachable ? AppColor.water : AppColor.secondaryText,
                    title: "Sync",
                    value: serverSyncSummary,
                    valueColor: serverSyncIsProblem ? AppColor.destructive : AppColor.secondaryText
                )
            }
            .buttonStyle(.plain)
            .disabled(serverSync.status == .syncing)
            .accessibilityHint("Syncs now")

            // Until the offer made after sign-in is answered.
            if isHandoffPending {
                actionRow("Send this iPhone's diary", icon: "square.and.arrow.up.on.square") {
                    isPresentingHandoff = true
                }
            }

            actionRow("Use this device only", icon: "iphone") {
                localHasEntries = LocalStore.shared.hasDiaryEntries()
                isChoosingLocalData = true
            }
        } header: {
            sectionHeader("YOUR DATA")
        } footer: {
            sectionFooter {
                if ServerConfig.isUnconfigured {
                    footnote(
                        "No server set yet — the address above is a placeholder, so nothing will load.",
                        color: AppColor.destructive
                    )
                } else {
                    footnote("Your diary is stored on this server and reaches every device you sign in on. This iPhone keeps a copy, so it works away from your server and catches up when it's back.")
                }
            }
        }
        .listRowBackground(AppColor.surface)
        .listRowSeparatorTint(AppColor.hairline)
    }

    /// Local mode's replacement for the server row and the account section.
    ///
    /// FOUR PARAGRAPHS DOWN TO ONE LINE AND A WARNING
    /// ----------------------------------------------
    /// This footer used to carry the whole story permanently: where the data
    /// lives, what iCloud is doing about it, and what switching to a server
    /// would do — the last of which explained a control nobody had touched
    /// yet. A wall of grey text under the one section that also holds a real
    /// warning is how a warning stops being read.
    ///
    /// Each sentence moved to where it's earned instead:
    ///
    ///   * **The warning stays, always.** It is the one thing here that is a
    ///     consequence rather than an explanation, and a warning behind a
    ///     disclosure is a warning nobody sees.
    ///   * **The switching caveat moved into the connect sheet**, which is
    ///     now the step that actually switches — said at the moment of the
    ///     decision, which is the only moment it matters.
    ///   * **The rest sits behind "What this means"**, the pattern Apple uses
    ///     for the same job in Settings.app's own privacy sections: a line of
    ///     reassurance on demand, not a lecture on arrival.
    private var localDataSection: some View {
        Section {
            iCloudRow

            // Neutral rather than accent: it's the way out of a problem the
            // app can't fix, not one of this screen's own controls, and three
            // pink rows in a row made none of them stand out.
            if sync.state.offersSystemSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                actionRow("Open iPhone Settings", icon: "gear", tint: AppColor.secondaryText) { openURL(url) }
            }

            // After a change of Apple ID, iOS can swap this device's iCloud
            // diary for the new account's; the copy kept here brings it back.
            if iCloudAccountChangedAt != nil, let backup = AutoBackup.beforeAccountChange() {
                actionRow("Restore this iPhone's backup from \(backup.date.formatted(date: .abbreviated, time: .omitted))", icon: "clock.arrow.circlepath") {
                    restoreAutomaticBackup()
                }
            }

            actionRow("Connect SparkyFitness server", icon: "externaldrive.connected.to.line.below") {
                isPresentingConnect = true
            }
        } header: {
            sectionHeader("YOUR DATA")
        } footer: {
            sectionFooter {
                if let warning = sync.state.dataLossWarning {
                    footnote(warning, color: AppColor.destructive)
                }

                if iCloudAccountChangedAt != nil, AutoBackup.beforeAccountChange() != nil {
                    footnote("This iPhone's iCloud account changed. If your diary is missing entries, restore the copy this iPhone kept.", color: AppColor.destructive)
                }

                if archiveNoticeIsNearTop, let archiveNotice {
                    footnote(archiveNotice, color: archiveNoticeIsError ? AppColor.destructive : AppColor.secondaryText)
                }

                if isShowingDataDetail {
                    // Not "nothing leaves the device", which is what this said
                    // before Module 11 and stopped being true the moment
                    // CloudKit mirroring went in. What is still true is that
                    // there is no account and no server.
                    footnote("Everything you log is stored on this iPhone. There's no account and no server.")

                    // The sync row states *what* iCloud is doing; this says
                    // what that means for the diary. See CloudSyncStatus for
                    // why the two aren't the same sentence.
                    footnote(sync.state.detail())
                }

                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                        isShowingDataDetail.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(isShowingDataDetail ? "Hide" : "What this means")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(isShowingDataDetail ? 180 : 0))
                    }
                    .appBody(12, weight: .semibold)
                    .foregroundStyle(AppColor.accent)
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .listRowBackground(AppColor.surface)
        .listRowSeparatorTint(AppColor.hairline)
    }

    /// iCloud's state, stated plainly. Not a toggle: syncing is a property of
    /// the account and the device, not a preference this app owns, and a
    /// switch here would imply the app can turn iCloud on. It can't.
    ///
    /// Label and state only; the sentence explaining it is in the footer. It
    /// was a subtitle first, which made a three-line row with the state
    /// floating beside the middle of it — and put a paragraph in the one slot
    /// the eye scans down for values.
    ///
    /// Colour carries the state before the words do: iCloud's own blue with a
    /// filled cloud when the diary really is up there, red with a struck-out
    /// one when it isn't and won't be. The in-between states — waiting,
    /// iCloud not answering — stay grey on purpose: they aren't the user's
    /// fault and there is nothing to fix, and an alarm colour for a state
    /// that resolves itself is how people learn to ignore the alarm.
    private var iCloudRow: some View {
        SettingsRow(
            icon: iCloudSymbol,
            tint: iCloudTint,
            title: "iCloud",
            value: sync.state.title,
            valueColor: iCloudTint
        )
        // One element, so VoiceOver reads the state with the label rather
        // than as two loose strings.
        .accessibilityElement(children: .combine)
    }

    private var iCloudTint: Color {
        if sync.state.backsUpTheDiary { return AppColor.iCloud }
        if sync.state.isProblem { return AppColor.destructive }
        return AppColor.secondaryText
    }

    private var iCloudSymbol: String {
        if sync.state.backsUpTheDiary { return "icloud.fill" }
        if sync.state.isProblem { return "icloud.slash.fill" }
        return "icloud"
    }

    // MARK: - The rest

    private var accountSection: some View {
        Section {
            SettingsRow(
                icon: "person.crop.circle",
                tint: AppColor.accent,
                title: "Signed in as",
                value: user.email
            )
            .accessibilityElement(children: .combine)
        } header: {
            sectionHeader("ACCOUNT")
        }
        .listRowBackground(AppColor.surface)
        .listRowSeparatorTint(AppColor.hairline)
    }

    private func applyDisplayMode() {
        AppDisplayMode.apply(.effective(raw: displayModeRaw, experimentalDark: experimentalDark))
    }

    /// Features that work but aren't finished. Dark mode is here, off by
    /// default, until it gets its proper pass — the app is light otherwise,
    /// whatever the phone is set to.
    ///
    /// Switching it on goes dark straight away: it used to keep the saved
    /// "System", so on a phone in light mode the switch seemed to do nothing.
    /// Then one choice — always dark, or follow the iPhone. "Light" isn't
    /// offered: that's the switch off.
    private var experimentalSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { experimentalDark },
                set: { isOn in
                    withAnimation(.snappy) {
                        if isOn { displayModeRaw = AppDisplayMode.dark.rawValue }
                        experimentalDark = isOn
                    }
                }
            )) {
                SettingsRow(
                    icon: "moon.fill",
                    tint: AppColor.protein,
                    title: "Dark mode",
                    subtitle: "Preview"
                )
            }
            .tint(AppColor.accent)

            if experimentalDark {
                Picker("Dark mode", selection: Binding(
                    get: { displayModeRaw == AppDisplayMode.system.rawValue ? AppDisplayMode.system : .dark },
                    set: { displayModeRaw = $0.rawValue }
                )) {
                    Text("Always").tag(AppDisplayMode.dark)
                    Text("Match iPhone").tag(AppDisplayMode.system)
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            }
        } header: {
            sectionHeader("EXPERIMENTAL")
        } footer: {
            sectionFooter {
                footnote("Dark mode isn't finished, so some screens may not look right yet. Turn it off to go back to light.")
            }
        }
        .listRowBackground(AppColor.surface)
        .listRowSeparatorTint(AppColor.hairline)
    }

    private var goalsSection: some View {
        Section {
            // Today's goal-not-set card is the other way in, but it disappears
            // the moment a goal exists — without this, a goal could be set once
            // and never changed again.
            NavigationLink {
                SetGoalsView {
                    NotificationCenter.default.post(name: .referenceDataChanged, object: nil)
                }
            } label: {
                SettingsRow(
                    icon: "target",
                    tint: AppColor.accent,
                    title: "Goals",
                    subtitle: "Calories, macros and water"
                )
            }

            NavigationLink {
                UnitPreferencesView {
                    NotificationCenter.default.post(name: .referenceDataChanged, object: nil)
                }
            } label: {
                SettingsRow(
                    icon: "ruler",
                    tint: AppColor.carbs,
                    title: "Units",
                    subtitle: "How weights and water are labelled"
                )
            }
        } header: {
            sectionHeader("GOALS & UNITS")
        }
        .listRowBackground(AppColor.surface)
        .listRowSeparatorTint(AppColor.hairline)
    }

    private var loggingSection: some View {
        Section {
            NavigationLink {
                MealCategoriesView {
                    NotificationCenter.default.post(name: .referenceDataChanged, object: nil)
                }
            } label: {
                SettingsRow(
                    icon: "fork.knife",
                    tint: AppColor.energy,
                    title: "Meals",
                    subtitle: "The meals food is logged into"
                )
            }

            NavigationLink {
                WaterContainersView {
                    NotificationCenter.default.post(name: .referenceDataChanged, object: nil)
                }
            } label: {
                SettingsRow(
                    icon: "drop.fill",
                    tint: AppColor.water,
                    title: "Water containers",
                    subtitle: "What one tap of “+” logs"
                )
            }
        } header: {
            sectionHeader("LOGGING")
        }
        .listRowBackground(AppColor.surface)
        .listRowSeparatorTint(AppColor.hairline)
    }

    /// Its own section rather than folded into LOGGING: this is a connection
    /// to another app with its own permission state, not a preference about
    /// this one.
    ///
    /// Deliberately just the switch and one line. The paragraph that used to
    /// sit here explained the max(Health, logged) rule in full, which is a
    /// thing to know *if* you turn this on — not a wall to read before
    /// deciding to.
    ///
    /// THE SWITCH NO LONGER CLAIMS WHAT IT CAN'T KNOW
    /// ----------------------------------------------
    /// It used to stay on whatever happened next — dismiss the Health sheet,
    /// deny it, drop it on the floor, and the app still showed a connection
    /// it did not have. Fixed as far as the API allows, which is not all the
    /// way: see the note at the top of HealthKitService. Concretely, the
    /// switch turns itself back off when the sheet was never answered, and
    /// the row says "No data from Health yet" instead of implying success
    /// when nothing has come back. What it will not do is turn itself off
    /// because a week was empty — a genuinely quiet week and a refusal look
    /// identical from here, and switching off someone's working setup on that
    /// evidence is the worse of the two mistakes.
    @ViewBuilder
    private var healthSection: some View {
        Section {
            if healthAvailable {
                // A binding rather than `$healthSyncEnabled` + `onChange`, and
                // the difference is a bug rather than a style: a binding's
                // setter runs only when the *switch* is moved, where onChange
                // runs on any write to the value. `connectHealth` writes the
                // value back when Health granted nothing, so with onChange the
                // revert re-entered the handler — a second haptic, and
                // `healthRequest` reset to `.idle`, wiping the broken heart
                // and the explanation before either could be seen.
                Toggle(isOn: Binding(
                    get: { healthSyncEnabled },
                    set: { wantsSync in
                        healthSyncEnabled = wantsSync
                        guard wantsSync else {
                            healthRequest = .idle
                            return
                        }
                        Task { await connectHealth() }
                    }
                )) {
                    SettingsRow(
                        icon: healthRequest.symbol(isOn: healthSyncEnabled),
                        tint: healthRequest.tint,
                        symbolEffect: healthRequest.effect(isOn: healthSyncEnabled),
                        title: "Sync Apple Health",
                        // Fixed, in every state. See HealthRequestState.footnote.
                        subtitle: "Counts active energy towards your daily burn"
                    )
                }
                .tint(AppColor.accent)

                // Asked for separately so the first sheet lists only what
                // every iPhone records. Turning it on is the signal there are
                // workouts in Health worth asking about.
                if healthSyncEnabled {
                    Toggle(isOn: Binding(
                        get: { importsWorkouts },
                        set: { wants in
                            importsWorkouts = wants
                            guard wants else { HealthSync.importsWorkouts = false; return }
                            Task { await connectWorkouts() }
                        }
                    )) {
                        SettingsRow(
                            icon: "figure.run",
                            tint: AppColor.accent,
                            title: "Import workouts",
                            subtitle: "From Apple Watch and fitness apps"
                        )
                    }
                    .tint(AppColor.accent)
                }
            } else {
                SettingsRow(
                    icon: "heart.slash",
                    tint: AppColor.placeholder,
                    title: "Apple Health",
                    subtitle: "Not available on this device"
                )
                .accessibilityElement(children: .combine)
            }
        } header: {
            sectionHeader("APPLE HEALTH")
        } footer: {
            sectionFooter {
                if healthAvailable {
                    healthFootnote(healthRequest.footnote(isOn: healthSyncEnabled))
                        // Two lines' worth of floor, so the one-line states
                        // don't pull the section up by 14pt as the switch is
                        // flipped. A floor rather than `lineLimit(2,
                        // reservesSpace:)`: that caps as well as reserves, and
                        // would truncate these sentences at large text sizes.
                        // Scaled, or the floor would stop being two lines the
                        // moment the type grew.
                        .frame(minHeight: healthFooterFloor, alignment: .top)
                }
            }
        }
        .listRowBackground(AppColor.surface)
        .listRowSeparatorTint(AppColor.hairline)
        // Crossfade the wording rather than re-laying the section out under
        // the thumb. With the row height now fixed and every state carrying a
        // footer, this is the only thing left that moves.
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: healthRequest)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: healthSyncEnabled)
    }

    /// The copy that works when neither iCloud nor a server can: a file the
    /// user keeps in Files, another app, or another device. Used rarely, so it
    /// sits below the things people open Settings for. Restore is local mode
    /// only — in server mode the server is the source of truth.
    private var backupSection: some View {
        Section {
            actionRow("Export diary", icon: "square.and.arrow.up", action: exportDiary)
            if isLocal {
                actionRow("Restore from export", icon: "square.and.arrow.down") {
                    // Mid-download, iCloud's copies of these rows haven't landed
                    // yet, so restoring would create a second row for each one
                    // (nothing can enforce uniqueness across CloudKit).
                    if case .syncing = sync.state {
                        showArchiveNotice("iCloud is still bringing this iPhone up to date. Restore once it says Synced.", isError: true)
                    } else {
                        isRestoringArchive = true
                    }
                }
            }
        } header: {
            sectionHeader("BACKUP")
        } footer: {
            sectionFooter {
                if let archiveNotice, !archiveNoticeIsNearTop {
                    footnote(archiveNotice, color: archiveNoticeIsError ? AppColor.destructive : AppColor.secondaryText)
                } else if let lastExportedAt {
                    footnote("Last exported \(lastExportedAt.formatted(.relative(presentation: .named))).")
                }
            }
        }
        .listRowBackground(AppColor.surface)
        .listRowSeparatorTint(AppColor.hairline)
    }

    private var aboutSection: some View {
        Section {
            SettingsRow(
                icon: "info.circle",
                tint: AppColor.secondaryText,
                title: "Version",
                value: versionString
            )
            .accessibilityElement(children: .combine)

            NavigationLink {
                AcknowledgementsView()
            } label: {
                SettingsRow(
                    icon: "heart.text.square",
                    tint: AppColor.accent,
                    title: "Acknowledgements",
                    subtitle: "Where the food and exercise data comes from"
                )
            }
        } header: {
            sectionHeader("ABOUT")
        }
        .listRowBackground(AppColor.surface)
        .listRowSeparatorTint(AppColor.hairline)
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        guard let build = info?["CFBundleVersion"] as? String, build != short else { return short }
        return "\(short) (\(build))"
    }

    /// Last on the screen and in a section of their own — the iOS convention,
    /// and the reason for it: these sit at the end of a scroll rather than
    /// next to the control someone came here to tap. Signing out was mid-list
    /// in ACCOUNT and the wipe was near the top of THIS DEVICE, both a
    /// thumb-slip from something harmless.
    ///
    /// Centred, unlike every other row, so the shape alone says this one isn't
    /// a setting.
    private var oneWayDoors: some View {
        Section {
            Button(role: .destructive) {
                // Warning, not selection: this is the one tap on the screen
                // that opens a door you can't close, and the alert takes a
                // beat to appear. The buzz lands first and says which kind of
                // thing you just touched.
                Haptics.warning()
                if isLocal { isConfirmingWipe = true } else { isConfirmingSignOut = true }
            } label: {
                Text(isLocal ? "Delete all local data" : "Sign out")
                    .appBody(15, weight: .semibold)
                    .foregroundStyle(AppColor.destructive)
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } footer: {
            sectionFooter {
                if let wipeError {
                    footnote(wipeError, color: AppColor.destructive)
                }
            }
        }
        .listRowBackground(AppColor.surface)
    }

    // MARK: - Actions

    /// Asks Health, then decides what the switch is allowed to claim.
    ///
    /// Three outcomes, and only one of them is a guess:
    ///
    ///   * **Unanswered or thrown** — the sheet was dismissed or never
    ///     appeared. Nothing was granted, so the switch goes back off and the
    ///     heart breaks. This is the case the old code got wrong.
    ///   * **Answered, and a week of energy came back** — it works. Heart
    ///     beats.
    ///   * **Answered, and nothing came back** — unknowable. Stays on,
    ///     because a refusal and a quiet week are the same from here, but the
    ///     row stops implying data is flowing.
    private func connectHealth() async {
        healthRequest = .asking
        let outcome = try? await health.requestAuthorization()
        // Not `&&`: the right-hand side is async, and `&&`'s autoclosure
        // can't await. Skipping the read when nothing was granted matters —
        // it would be a query the app has no permission to make.
        var hasEnergy = false
        if outcome == .answered {
            hasEnergy = await health.hasRecentEnergy(days: 7)
        }
        let resolved = HealthRequestState.resolve(outcome: outcome, hasRecentEnergy: hasEnergy)

        healthSyncEnabled = resolved.keepsSwitchOn
        healthRequest = resolved

        // The only haptic in this flow, and the only one that carries
        // information: the switch has just moved back on its own.
        //
        // The three that were here before — a tick on the flip, then a
        // success or an error when the request finished — were one tap
        // producing a burst of unrelated buzzes, and iOS switches don't
        // vibrate in the first place: Settings.app's are silent, because the
        // switch moving under your thumb is already the feedback. A
        // notification haptic for an outcome the user is watching for is the
        // same noise a beat later.
        if resolved == .refused {
            Haptics.warning()
        }
    }

    /// Workouts and their distances. A dismissed sheet granted nothing, so
    /// the switch goes back off, as the main Health switch does.
    private func connectWorkouts() async {
        let answered = (try? await health.requestAuthorization(includingWorkouts: true)) == .answered
        HealthSync.importsWorkouts = answered
        importsWorkouts = answered
        if answered {
            NotificationCenter.default.post(name: .referenceDataChanged, object: nil)
        } else {
            Haptics.warning()
        }
    }

    private func switchMode(to mode: AppMode) {
        // Leaving server mode stops its syncing; the copy stays on this
        // device, so coming back resumes from it.
        if mode == .local { ServerSync.shared.deactivate(removingCopy: false) }
        AppMode.current = mode
        Haptics.success()
    }

    /// The sync row's value: what the user needs to know about their
    /// changes, not what the sync engine is doing.
    private var serverSyncSummary: String {
        let waiting = serverSync.pendingCount
        if !serverSync.isReachable && serverSync.status != .syncing {
            return waiting > 0 ? "Offline · \(waiting) waiting" : "Offline"
        }
        switch serverSync.status {
        case .syncing:
            return "Syncing…"
        case .offline:
            return waiting > 0 ? "Offline · \(waiting) waiting" : "Offline"
        case .failed:
            return waiting > 0 ? "\(waiting) not synced" : "Sync problem"
        case .idle:
            if waiting > 0 { return "\(waiting) waiting" }
            guard let last = serverSync.lastSyncedAt else { return "Up to date" }
            return "Synced \(last.formatted(.relative(presentation: .named)))"
        }
    }

    /// Out of range, the copy comes from what this iPhone already has.
    private var offlineCopyNote: String {
        guard !serverSync.isReachable else { return "" }
        let when = serverSync.lastSyncedAt.map { " (last synced \($0.formatted(.relative(presentation: .named))))" } ?? ""
        return "\n\nYour server can't be reached, so this copies what this iPhone has\(when) plus anything logged here since."
    }

    private var serverSyncIsProblem: Bool {
        if case .failed = serverSync.status { return true }
        return false
    }

    /// Moves server mode's copy of the diary here and switches — see
    /// `ServerToDeviceMove`.
    private func startImport() {
        importError = nil
        importProgress = ServerPull.Progress(daysRead: 0, totalDays: 0)
        importTask = Task {
            do {
                try await ServerToDeviceMove.run(user: user)
                importTask = nil
                importProgress = nil
                switchMode(to: .local)
            } catch is CancellationError {
                importTask = nil
                importProgress = nil
            } catch {
                importTask = nil
                importProgress = nil
                importError = error.localizedDescription
                Haptics.error()
            }
        }
    }

    private func cancelImport() {
        importTask?.cancel()
        importTask = nil
        importProgress = nil
        importError = nil
    }

    /// Starting fresh empties the store, and a CloudKit store's deletes
    /// reach iCloud — unlike Delete all local data, an empty diary that
    /// iCloud refilled wouldn't be fresh — so the alert has to say so.
    private var startFreshReach: String {
        LocalStore.shared.isCloudKitEnabled ? ", here and in iCloud" : ""
    }

    /// An empty diary, whatever this device held before, starting today.
    private func startFresh() {
        do {
            try LocalStore.shared.deleteEverything()
        } catch {
            importError = "Couldn't clear this iPhone's diary. \(error.localizedDescription)"
            Haptics.error()
            return
        }
        UserDefaults.standard.removeObject(forKey: LocalAPIClient.firstUseKey)
        NotificationCenter.default.post(name: .referenceDataChanged, object: nil)
        switchMode(to: .local)
    }

    /// Only this iPhone's copy goes — iCloud's is never touched (see
    /// LocalStore.eraseThisDeviceCopy) — so the message says whether there
    /// is a copy to come back to. "Synced" is the last event that
    /// succeeded, not proof the newest entries were uploaded, so even that
    /// case doesn't promise them.
    private var wipeMessage: String {
        let ending = " This iPhone's automatic backups are removed too. You'll return to the start screen."
        if sync.state.backsUpTheDiary {
            return "Only this iPhone's copy is removed. Your iCloud copy stays, and comes back when you choose “On this iPhone” again — though anything logged in the last few moments may not have reached it yet." + ending
        }
        switch sync.state {
        case .unavailable(.notSignedIn), .unavailable(.restricted), .unavailable(.notConfigured):
            return "Your diary isn't in iCloud, so once it's removed from this iPhone it can't be recovered unless you export a copy first." + ending
        default:
            return "iCloud hasn't confirmed it has your whole diary, so anything not yet there can't be recovered unless you export a copy first." + ending
        }
    }

    /// Erases this iPhone's copy and goes back to the start screen, where the
    /// choice is made again — this device (which brings an iCloud copy back
    /// down) or a server. Staying in an emptied local mode left the user in
    /// Settings with no sign anything had happened.
    private func wipeLocalData() {
        // Whatever the sync state said, a CloudKit store gets its iCloud
        // history back on the next open, and the first-use date floors how
        // far back day navigation reaches; only a store with no iCloud copy
        // starts genuinely new.
        let keepsCloudCopy = LocalStore.shared.isCloudKitEnabled
        do {
            try LocalStore.shared.eraseThisDeviceCopy()
            // The reopened store fetches the iCloud diary from the start, so
            // it's a fresh install again until that has arrived.
            if keepsCloudCopy { sync.restartInitialImport() }
            wipeError = nil
            Haptics.success()
            NotificationCenter.default.post(name: .referenceDataChanged, object: nil)
            if !keepsCloudCopy {
                UserDefaults.standard.removeObject(forKey: LocalAPIClient.firstUseKey)
            }
            UserDefaults.standard.removeObject(forKey: OnboardingGate.localKey)
            AppMode.current = nil
        } catch {
            // Reported rather than swallowed: a wipe that silently half-ran
            // would leave the user believing their data is gone when it isn't.
            wipeError = "Couldn't delete everything — some data may remain. \(error.localizedDescription)"
            Haptics.error()
        }
    }

    /// Builds the file first, then opens the save sheet, so a failure to
    /// build is reported here rather than as a sheet that saves nothing.
    private func exportDiary() {
        do {
            // Server mode exports this device's copy of the server diary —
            // the copy that matters most when the server is the thing gone.
            let data = try DiaryArchive(from: isLocal ? LocalStore.shared : ServerSync.shared.store).encoded()
            exportDocument = DiaryArchiveDocument(data: data)
            isExportingArchive = true
        } catch {
            showArchiveNotice("Couldn't build the export. \(error.localizedDescription)", isError: true)
        }
    }

    /// Merges a file into this diary. Nothing is deleted, and a row edited
    /// here since the file was made keeps this iPhone's version.
    private func restoreDiary(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let archive = try DiaryArchive.decode(Data(contentsOf: url))
            let result = try archive.restore(into: LocalStore.shared)
            // Older days it brought become reachable on their own: the
            // first-use date never sits after the diary's first entry, and
            // this notice has the session re-read it.
            NotificationCenter.default.post(name: .referenceDataChanged, object: nil)
            let summary = result.added + result.updated == 0
                ? "Restored — this iPhone already had everything in that file."
                : "Restored \(result.added) new and \(result.updated) updated items. \(result.kept) were already up to date here."
            showArchiveNotice(summary, isError: false)
            Haptics.success()
        } catch {
            showArchiveNotice(error.localizedDescription, isError: true)
        }
    }

    private var iCloudAccountChangedAt: Date? {
        iCloudAccountChangedAtRaw > 0 ? Date(timeIntervalSinceReferenceDate: iCloudAccountChangedAtRaw) : nil
    }

    /// Merges the newest automatic backup back in: nothing is deleted, the
    /// newer copy of each row wins.
    private func restoreAutomaticBackup() {
        do {
            if let backup = AutoBackup.beforeAccountChange() {
                let result = try AutoBackup.restore(backup)
                NotificationCenter.default.post(name: .referenceDataChanged, object: nil)
                showArchiveNotice("Restored \(result.added) new and \(result.updated) updated items from this iPhone's backup.", isError: false, nearTop: true)
                Haptics.success()
            }
            ICloudIdentity.changedAt = nil
        } catch {
            showArchiveNotice(error.localizedDescription, isError: true, nearTop: true)
        }
    }

    private func showArchiveNotice(_ text: String, isError: Bool, nearTop: Bool = false) {
        archiveNotice = text
        archiveNoticeIsError = isError
        archiveNoticeIsNearTop = nearTop
        if isError { Haptics.error() }
    }

    // MARK: - Section furniture

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .appBody(12, weight: .semibold)
            .foregroundStyle(AppColor.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }

    /// Footers carry the explaining, which is what lets a row stay one line.
    @ViewBuilder
    private func sectionFooter<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
        }
        .padding(.top, 2)
    }

    /// The Health footer, which is the whole tap target when it carries a
    /// link — a two-line block is a better target than the three words at the
    /// end of it, and VoiceOver gets one button reading the whole sentence
    /// rather than a paragraph with a link buried in it.
    @ViewBuilder
    private func healthFootnote(_ line: Footnote) -> some View {
        let color = line.isProblem ? AppColor.destructive : AppColor.secondaryText
        let body = Text(line.text).foregroundColor(color)
            + Text(line.link ?? "").foregroundColor(AppColor.accent)

        if line.link == nil {
            body
                .appBody(12)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Button(action: openHealthApp) {
                body
                    .appBody(12)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(line.text)\(line.link ?? "")")
            .accessibilityAddTraits(.isButton)
        }
    }

    /// Health owns this permission and won't hand it back, so the most the
    /// app can do is open the door. No `canOpenURL` guard: that needs the
    /// scheme declared in Info.plist to answer truthfully, and `openURL`'s
    /// own completion already reports whether it worked.
    private func openHealthApp() {
        guard let url = URL(string: "x-apple-health://") else { return }
        openURL(url) { opened in
            guard !opened, let fallback = URL(string: UIApplication.openSettingsURLString) else { return }
            openURL(fallback)
        }
    }

    private func footnote(_ text: String, color: Color = AppColor.secondaryText) -> some View {
        Text(text)
            .appBody(12)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A row that does something here rather than opening a screen, so it has
    /// no chevron — the difference is worth keeping visible.
    private func actionRow(
        _ title: String,
        icon: String,
        tint: Color = AppColor.accent,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            SettingsRow(icon: icon, tint: tint, title: title, titleColor: tint)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Apple Health's switch

/// What the Health row is entitled to say, and the heart that says it.
///
/// The animation is doing a job, not decorating: a permission sheet that has
/// just closed leaves the user looking at a switch, wondering whether the
/// thing happened. A heart that starts beating is the answer, arriving before
/// any sentence would be read.
enum HealthRequestState: Equatable {
    /// Off, or on from a previous launch with nothing checked this session.
    case idle
    /// The Health sheet is up.
    case asking
    /// Asked, answered, and energy is arriving.
    case flowing
    /// Asked and answered, but Health has handed over nothing. Might be a
    /// refusal, might be a quiet week — the API won't say.
    case silent
    /// Definitely not granted: the sheet was dismissed without an answer.
    case refused

    /// The whole decision the Health switch makes, in one place so it can be
    /// checked without a screen. `outcome` is nil when the request threw.
    ///
    /// Note what is *not* here: a path from "no energy came back" to
    /// `.refused`. That inference is the tempting one and it's wrong — a
    /// quiet week reads identically — so an empty read lands on `.silent`,
    /// which keeps the switch on and stops the row claiming data is flowing.
    static func resolve(
        outcome: HealthAuthorizationOutcome?,
        hasRecentEnergy: Bool
    ) -> HealthRequestState {
        guard outcome == .answered else { return .refused }
        return hasRecentEnergy ? .flowing : .silent
    }

    /// Whether the switch may stay on. Only a definite "nothing was granted"
    /// turns it back off.
    var keepsSwitchOn: Bool { self != .refused }

    func symbol(isOn: Bool) -> String {
        switch self {
        // SF Symbols has no broken heart; a struck-through one is the nearest
        // thing that reads as "this didn't happen" rather than "this is off".
        case .refused: return "heart.slash.fill"
        case .silent: return "heart"
        case .idle: return isOn ? "heart.fill" : "heart"
        case .asking, .flowing: return "heart.fill"
        }
    }

    var tint: Color {
        self == .refused ? AppColor.destructive : AppColor.accent
    }

    /// Only the live states animate. A heart beating forever on a settings
    /// screen is a distraction with no information in it, so `.flowing`
    /// pulses — the confirmation — and `.idle` sits still.
    func effect(isOn: Bool) -> SettingsRow.SymbolEffect {
        switch self {
        case .flowing: return .heartbeat
        case .asking: return .waiting
        case .refused: return .break
        case .idle, .silent: return .none
        }
    }

    /// The line under the section, in every state including off.
    ///
    /// The state used to be the row's *subtitle*, which made the row change
    /// height as the switch was flipped — "Counts active energy towards your
    /// daily burn" wraps to two lines and "No data from Health yet" doesn't,
    /// so the thing under your thumb shrank at the moment you touched it.
    /// Reserving two lines would have fixed the wobble by truncating that
    /// sentence at large text sizes, which trades a cosmetic problem for a
    /// legibility one.
    ///
    /// So the row keeps one fixed subtitle and the *footer* carries the
    /// state, which is the division of labour iOS already uses: the row says
    /// what the setting is, the footer says what is happening. Every state
    /// returns a line — off included — so the block never collapses to
    /// nothing, and each is kept to roughly two lines so the height barely
    /// moves between them.
    func footnote(isOn: Bool) -> Footnote {
        switch self {
        case .refused:
            return Footnote(
                text: "Health didn't grant access, so this stayed off. ",
                link: "Check it in Health",
                isProblem: true
            )
        case .asking:
            return Footnote(text: "Waiting for Health…")
        case .silent:
            // The one state where the app is switched on and may well be
            // getting nothing. The link goes where the fix is, because
            // "Health › Sharing › Apps" is a path to follow by hand and a
            // button is not.
            return Footnote(
                text: "No data from Health yet. Allow Active Energy under Sharing › Apps. ",
                link: "Open Health"
            )
        case .flowing:
            return Footnote(text: "Logged workouts still count — whichever total is higher wins.")
        case .idle:
            return isOn
                ? Footnote(text: "Logged workouts still count — whichever total is higher wins.")
                : Footnote(text: "Sparky only reads from Health. It never writes to it.")
        }
    }
}

/// A footer line, optionally ending in a tappable phrase.
///
/// The phrase is part of the same paragraph rather than a row of its own, and
/// that's deliberate: a row appearing under the switch would put the section
/// back to changing height between states, which is the thing the fixed
/// subtitle and the two-line floor exist to prevent.
/// Copying the server's diary: a count while it reads, or what went wrong.
private struct ImportProgressSheet: View {
    let progress: ServerPull.Progress?
    let error: String?
    let onRetry: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if let error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(AppColor.destructive)
                    .accessibilityHidden(true)
                Text("Couldn't copy your diary")
                    .appBody(17, weight: .semibold)
                    .foregroundStyle(AppColor.ink)
                Text("Nothing on this iPhone changed, and you're still using the server. \(error)")
                    .appBody(13)
                    .foregroundStyle(AppColor.secondaryText)
                    .multilineTextAlignment(.center)
                PrimaryButton(title: "Try again", action: onRetry)
            } else {
                Text("Copying your diary")
                    .appBody(17, weight: .semibold)
                    .foregroundStyle(AppColor.ink)
                if let progress, progress.totalDays > 0 {
                    ProgressView(value: Double(progress.daysRead), total: Double(progress.totalDays))
                        .tint(AppColor.accent)
                    Text("\(progress.daysRead) of \(progress.totalDays) days")
                        .appBody(13)
                        .foregroundStyle(AppColor.secondaryText)
                        .monospacedDigit()
                } else {
                    ProgressView().tint(AppColor.accent)
                }
                Text("Keep the app open until it finishes.")
                    .appBody(12)
                    .foregroundStyle(AppColor.placeholder)
            }
            Button(error == nil ? "Cancel" : "Close", action: onCancel)
                .appBody(15, weight: .semibold)
                .foregroundStyle(AppColor.accent)
                .frame(minHeight: 44)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColor.surface)
    }
}

struct Footnote {
    let text: String
    var link: String? = nil
    var isProblem: Bool = false
}

// MARK: - The row

/// One settings row: a tinted glyph, a title, an optional one-line subtitle,
/// and an optional current value on the trailing edge.
///
/// The glyph sits on a soft tint rather than a saturated square. The saturated
/// version is what Settings.app draws, but this app's tokens invert for dark
/// mode — `energy` goes from a deep green to a bright mint — so a white glyph
/// on top would be legible in one mode and washed out in the other. A tinted
/// glyph on a 16%-opacity tile reads the same in both, and sits better on the
/// warm surface this app uses anyway.
///
/// At accessibility text sizes the value drops under the title instead of
/// fighting it for the same line — at AX2 a side-by-side server address had
/// collapsed to "http:/…l:3010", which is the one row where every character
/// is load-bearing. Same reason Settings.app restacks its own rows.
struct SettingsRow: View {
    /// The animations a row's glyph can carry. An enum rather than a
    /// `SymbolEffect` parameter because the effect types aren't a single
    /// protocol you can store — and because a row should be told what it is
    /// showing, not how to animate.
    enum SymbolEffect: Equatable {
        case none
        /// Permission granted and data arriving.
        case heartbeat
        /// Waiting on another app's sheet.
        case waiting
        /// It didn't happen. One knock, not a loop.
        case `break`
    }

    let icon: String
    let tint: Color
    var symbolEffect: SymbolEffect = .none
    let title: String
    var titleColor: Color = AppColor.ink
    var subtitle: String? = nil
    var value: String? = nil
    var valueColor: Color = AppColor.secondaryText
    /// Draws the chevron a `NavigationLink` would add for itself. Set only on
    /// rows that open a sheet, so opening something always looks the same
    /// whether it pushes or presents.
    var opensDetail: Bool = false

    @Environment(\.dynamicTypeSize) private var typeSize
    /// The tile grows with the text, or a 29pt square next to 30pt type reads
    /// as a bullet point. Capped, because past that it starts pushing the
    /// label off the row.
    @ScaledMetric(relativeTo: .subheadline) private var tile: CGFloat = 29
    @ScaledMetric(relativeTo: .subheadline) private var glyphSize: CGFloat = 15
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isStacked: Bool { typeSize.isAccessibilitySize }
    private var tileSide: CGFloat { min(tile, 44) }

    var body: some View {
        HStack(spacing: 12) {
            glyph(icon)
                .frame(width: tileSide, height: tileSide)
                .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                // Decoration — the row's own text says what it is.
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .appBody(15, weight: .semibold)
                    .foregroundStyle(titleColor)
                if let subtitle {
                    Text(subtitle)
                        .appBody(12)
                        .foregroundStyle(AppColor.placeholder)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isStacked, let value {
                    valueText(value, wraps: true)
                }
            }

            if !isStacked, let value {
                Spacer(minLength: 8)
                valueText(value, wraps: false)
            } else {
                Spacer(minLength: 0)
            }

            if opensDetail {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColor.placeholder.opacity(0.6))
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 5)
        .frame(minHeight: 34)
        .contentShape(Rectangle())
    }

    /// `.symbolEffect` can't be applied conditionally to one `Image` and then
    /// have the branches type-check as the same view, so each case returns
    /// its own — which also keeps `reduceMotion` honoured in one place.
    @ViewBuilder
    private func glyph(_ name: String) -> some View {
        let base = Image(systemName: name)
            .font(.system(size: min(glyphSize, 22), weight: .semibold))
            .foregroundStyle(tint)

        let effect = reduceMotion ? SymbolEffect.none : symbolEffect
        if #available(iOS 18, *) {
            switch effect {
            case .none:
                base
            case .heartbeat:
                // A repeating bounce, which is the pump. Bounded in practice:
                // `.flowing` is only ever set by a request made in this session,
                // so the heart beats as the answer to a question just asked and
                // is back to still the next time the screen is opened.
                base.symbolEffect(.bounce, options: .repeating)
            case .waiting:
                base.symbolEffect(.breathe, options: .repeating)
            case .break:
                base.symbolEffect(.bounce, options: .nonRepeating)
            }
        } else {
            // iOS 17 can only bounce on a value change, and has no breathe:
            // both loops pulse, and the one knock is left out.
            switch effect {
            case .none, .break:
                base
            case .heartbeat, .waiting:
                base.symbolEffect(.pulse, options: .repeating)
            }
        }
    }

    /// Truncated in the middle when it has to fit on one line: a server
    /// address differs at both ends, and a tail-truncated one hides the port,
    /// which is the part most likely to be wrong.
    private func valueText(_ value: String, wraps: Bool) -> some View {
        Text(value)
            .appBody(13)
            .foregroundStyle(valueColor)
            .lineLimit(wraps ? nil : 1)
            .truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: wraps)
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
