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
//    ABOUT       — information, not a control
//    (unheaded)  — irreversible
//

import SwiftUI
import UIKit

struct SettingsView: View {
    let user: SessionUser
    var onSignOut: () -> Void = {}

    @AppStorage(ServerConfig.defaultsKey) private var serverURL = ""
    @AppStorage(AppMode.defaultsKey) private var modeRaw = AppMode.server.rawValue
    @AppStorage(HealthSync.defaultsKey) private var healthSyncEnabled = false
    @AppStorage(AppDisplayMode.defaultsKey) private var displayModeRaw = AppDisplayMode.system.rawValue

    @State private var isPresentingServer = false
    @State private var isPresentingConnect = false
    @State private var isConfirmingWipe = false
    @State private var isConfirmingSignOut = false
    @State private var wipeError: String?
    /// Collapsed by default. See `localDataSection`.
    @State private var isShowingDataDetail = false
    @State private var healthRequest: HealthRequestState = .idle

    @ObservedObject private var sync = CloudSyncStatus.shared
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
                if isLocal { localDataSection } else { serverSection }

                // Server mode only. Local mode has no account, and showing one
                // inert would imply it might one day apply here.
                if !isLocal { accountSection }

                appearanceSection
                goalsSection
                loggingSection
                healthSection
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
        .onChange(of: displayModeRaw) { _, newValue in
            AppDisplayMode.apply(AppDisplayMode(rawValue: newValue) ?? .system)
        }
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
            .presentationDetents([.medium, .large])
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
                title: "Connect Sparky Server",
                saveTitle: "Connect",
                note: "Your on-device data stays on this iPhone and isn't sent to the server. It reappears if you switch back."
            ) {
                switchMode(to: .server)
            }
            .presentationDetents([.medium, .large])
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
        .alert("Sign out?", isPresented: $isConfirmingSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign out", role: .destructive, action: onSignOut)
        } message: {
            // Nothing is lost — it all lives on the server — and saying so is
            // the point: without it this reads as destructive as the wipe.
            Text("Your diary stays on the server. You'll need your email and password to sign back in.")
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

            actionRow("Use this device only", icon: "iphone") { switchMode(to: .local) }
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
                    footnote("Your diary is stored on this server and reaches every device you sign in on.")
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

            actionRow("Connect Sparky server", icon: "externaldrive.connected.to.line.below") {
                isPresentingConnect = true
            }
        } header: {
            sectionHeader("YOUR DATA")
        } footer: {
            sectionFooter {
                if let warning = sync.state.dataLossWarning {
                    footnote(warning, color: AppColor.destructive)
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

    private var appearanceSection: some View {
        Section {
            Picker("Appearance", selection: $displayModeRaw) {
                ForEach(AppDisplayMode.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        } header: {
            sectionHeader("APPEARANCE")
        }
        .listRowBackground(AppColor.surface)
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

    private var aboutSection: some View {
        Section {
            SettingsRow(
                icon: "info.circle",
                tint: AppColor.secondaryText,
                title: "Version",
                value: versionString
            )
            .accessibilityElement(children: .combine)
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

    private func switchMode(to mode: AppMode) {
        AppMode.current = mode
        Haptics.success()
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
                : Footnote(text: "Adds Health's active energy to your daily burn.")
        }
    }
}

/// A footer line, optionally ending in a tappable phrase.
///
/// The phrase is part of the same paragraph rather than a row of its own, and
/// that's deliberate: a row appearing under the switch would put the section
/// back to changing height between states, which is the thing the fixed
/// subtitle and the two-line floor exist to prevent.
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

        switch reduceMotion ? SymbolEffect.none : symbolEffect {
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
