//
//  SettingsView.swift
//  SwiftSparkyFitness
//
//  Settings: the server address, daily goals, and signing out.
//
//  This replaced the placeholder tab specifically because the backend URL
//  stopped being a hardcoded constant — without somewhere to type it, a fresh
//  install has no way to reach a server at all. Units and water containers
//  still belong here later.
//

import SwiftUI

struct SettingsView: View {
    let user: SessionUser
    var onSignOut: () -> Void = {}

    @AppStorage(ServerConfig.defaultsKey) private var serverURL = ""
    @State private var draft = ""
    @State private var savedNotice = false
    @State private var isPresentingGoals = false
    @State private var isPresentingMeals = false
    @State private var isPresentingWater = false
    @AppStorage(HealthSync.defaultsKey) private var healthSyncEnabled = false
    @FocusState private var isFieldFocused: Bool

    private let health: HealthKitReading = HealthKitService.shared
    private var healthAvailable: Bool { health.isAvailable }

    /// Presenting the sheet is all the app can do. HealthKit deliberately
    /// won't say whether reading was allowed, so the toggle records that the
    /// user opted in, not that access was granted.
    private func connectHealth() async {
        try? await health.requestAuthorization()
    }

    private var effective: String { ServerConfig.urlString }
    private var isDirty: Bool { draft.trimmingCharacters(in: .whitespaces) != effective }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings")
                    .appDisplay(26)
                    .foregroundStyle(AppColor.ink)

                section("SERVER") {
                    Text("SwiftSparkyFitness talks to a SparkyFitness server you run yourself.")
                        .appBody(13)
                        .foregroundStyle(AppColor.secondaryText)

                    AppTextField(
                        placeholder: ServerConfig.placeholder,
                        text: $draft,
                        style: .filled,
                        keyboardType: .URL,
                        submitLabel: .done,
                        focus: $isFieldFocused
                    )
                    .onSubmit(save)

                    // The Bonjour name is stabler than the LAN IP, which changes
                    // on every DHCP renewal — the exact drift that made the old
                    // hardcoded address break repeatedly.
                    Text("Tip: use your Mac's Bonjour name (scutil --get LocalHostName, plus .local) rather than its IP — the IP changes on every DHCP renewal.")
                        .appBody(12)
                        .foregroundStyle(AppColor.placeholder)

                    if ServerConfig.isUnconfigured {
                        Text("No server set yet — using the placeholder, so nothing will load.")
                            .appBody(12)
                            .foregroundStyle(AppColor.destructive)
                    }

                    PrimaryButton(title: savedNotice ? "Saved" : "Save server address", action: save)
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
                    Text("The container the “+” logs from. Without one it adds the server's default 250 ml.")
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

                section("APPLE HEALTH") {
                    Text("Counts the active energy Health has recorded towards your daily burn. Your logged workouts still count — the server takes whichever total is higher, so nothing is counted twice.")
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

                section("ABOUT") {
                    row("Version", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                }
            }
            .padding(AppSpacing.screenPad)
            .padding(.bottom, 24)
        }
        .background(AppColor.background)
        .task { draft = effective }
        .onChange(of: draft) { _, _ in savedNotice = false }
        .sheet(isPresented: $isPresentingGoals) {
            SetGoalsView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isPresentingMeals) {
            MealCategoriesView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isPresentingWater) {
            WaterContainersView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, URL(string: trimmed) != nil else {
            Haptics.error()
            return
        }
        serverURL = trimmed
        isFieldFocused = false
        Haptics.success()
        withAnimation(.snappy(duration: 0.2)) { savedNotice = true }
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
