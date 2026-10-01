//
//  ModeChoiceView.swift
//  SwiftSparkyFitness
//
//  The first thing a fresh install shows: this iPhone, or your own server.
//
//  It comes before auth deliberately. Signing in only means something once
//  there's a server to sign in to, so asking for an email first would make the
//  on-device path look like a fallback for people who failed at setup rather
//  than a supported way to use the app.
//
//  WHAT EACH CARD PROMISES
//  -----------------------
//  The question is where the diary lives, so that's what the title asks,
//  and each card ends on the one fact that decides it: the device card on
//  where its backup goes, the server card on what you need before you
//  start. The device card's old caveat — "Nothing is backed up" — stopped
//  being true when the store began mirroring to iCloud, and it was the
//  strongest reason on screen not to pick the option most people should.
//
//  THE SERVER PATH STARTS WITH ITS ADDRESS
//  ---------------------------------------
//  Choosing the server used to store the mode at once and go straight to
//  login against the shipped placeholder address — which can never answer,
//  so the first screen a new server user saw was "Can't reach the server",
//  with no way back here. The address is now the first step, in a sheet:
//  cancelling it leaves the user on this screen with nothing changed, and
//  only a saved address commits the choice.
//

import SwiftUI

struct ModeChoiceView: View {
    /// Called once a mode is stored, so the caller can restore the session —
    /// which in local mode is synthetic and instant.
    var onChosen: () async -> Void

    @State private var isConnectingServer = false
    /// Set by the sheet's save, acted on once it has finished dismissing:
    /// storing the mode swaps this whole view out, and doing that while its
    /// sheet is still animating away leaves the sheet without a presenter.
    @State private var serverIsReady = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                brandLockup
                    .padding(.top, 36)

                Text("Where should your diary live?")
                    .appDisplay(28)
                    .foregroundStyle(AppColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 28)

                Text("Pick one to get started. You can switch anytime in Settings.")
                    .appBody(15)
                    .foregroundStyle(AppColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)

                choice(
                    icon: "iphone",
                    title: "On this iPhone",
                    badge: "Recommended",
                    detail: "Start logging right away. No account or server needed.",
                    note: Note(icon: "icloud", text: "Private to you, and backed up to iCloud when you're signed in."),
                    isPrimary: true
                ) { choose(.local) }
                .padding(.top, 28)

                choice(
                    icon: "server.rack",
                    title: "On my SparkyFitness server",
                    badge: nil,
                    detail: "Sign in to a server you host yourself, and use the same diary on the web and your other devices.",
                    note: Note(icon: "link", text: "You'll need your server's address and an account on it."),
                    isPrimary: false
                ) { isConnectingServer = true }
                .padding(.top, 12)
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.bottom, 32)
        }
        .background(AppColor.background)
        .sheet(isPresented: $isConnectingServer, onDismiss: {
            guard serverIsReady else { return }
            serverIsReady = false
            choose(.server)
        }) {
            ServerAddressSheet(
                title: "Connect to your server",
                saveTitle: "Connect",
                note: "Next, you'll sign in with your SparkyFitness account."
            ) { serverIsReady = true }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private func choose(_ mode: AppMode) {
        AppMode.current = mode
        Haptics.success()
        Task { await onChosen() }
    }

    /// The same ring-and-wordmark lockup the login screen opens with, so the
    /// first two screens read as one app. Decorative to VoiceOver.
    private var brandLockup: some View {
        HStack(spacing: 10) {
            RingChart(
                layers: [
                    RingLayer(progress: 0.78, color: AppColor.accent),
                    RingLayer(progress: 0.52, color: AppColor.energyGraphic),
                    RingLayer(progress: 0.64, color: AppColor.water),
                ],
                diameter: 40, trackWidth: 4, gap: 2.5
            )
            Text("Sparky")
                .appDisplay(22)
                .foregroundStyle(AppColor.ink)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sparky")
    }

    private struct Note {
        let icon: String
        let text: String
    }

    private func choice(
        icon: String,
        title: String,
        badge: String?,
        detail: String,
        note: Note,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(isPrimary ? AppColor.accent : AppColor.ink)
                    .frame(width: 44, height: 44)
                    .background(
                        isPrimary ? AppColor.accentSoft : AppColor.inputBackground,
                        in: RoundedRectangle(cornerRadius: AppRadius.sm)
                    )

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(title)
                            .appBody(17, weight: .semibold)
                            .foregroundStyle(AppColor.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if let badge {
                            Text(badge)
                                .appBody(11, weight: .semibold)
                                .foregroundStyle(AppColor.accent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(AppColor.accentSoft, in: Capsule())
                                .fixedSize()
                        }
                    }
                    Text(detail)
                        .appBody(14)
                        .foregroundStyle(AppColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: note.icon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(note.text)
                            .appBody(12)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(AppColor.placeholder)
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.forward")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColor.placeholder)
                    .frame(height: 44)
            }
            .padding(16)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(isPrimary ? AppColor.accent : AppColor.hairline, lineWidth: isPrimary ? 2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        // One element per option: VoiceOver reads the choice and its
        // consequence together rather than as loose texts.
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ModeChoiceView {}
}
