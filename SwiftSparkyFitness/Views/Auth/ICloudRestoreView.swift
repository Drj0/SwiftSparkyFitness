//
//  ICloudRestoreView.swift
//  SwiftSparkyFitness
//
//  Shown when this iPhone's diary is chosen on a fresh install (or after
//  "Delete all local data"), until iCloud's copy has come down.
//
//  Without it a returning user landed on an empty Today with nothing saying
//  their diary was on its way: it looked lost, and onboarding opened over it
//  and replaced their goals. A new user waits only for iCloud to answer that
//  there's nothing, usually a second or two.
//
//  Never a trap: after a moment, or as soon as iCloud reports a problem,
//  "Continue" lets the user in. Whatever is still coming arrives on its own,
//  and Today says so meanwhile (`ICloudRestoreBanner`).
//

import SwiftUI

struct ICloudRestoreView: View {
    @ObservedObject var cloud: CloudSyncStatus
    var onContinue: () -> Void

    @State private var offersContinue = false

    /// A reason iCloud can't deliver right now, worth saying and worth not
    /// waiting on.
    private var problem: String? {
        switch cloud.state {
        case .failed(let message): return message
        case .unavailable(.temporarilyUnavailable), .unavailable(.unknown): return cloud.state.detail()
        default: return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(AppColor.accent)
                .frame(width: 64, height: 64)
                .background(AppColor.accentSoft, in: Circle())
                .accessibilityHidden(true)

            Text("Checking iCloud for your diary")
                .appDisplay(24)
                .foregroundStyle(AppColor.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 20)

            Text("If you've used Sparky before, your entries and goals are on their way back to this iPhone. This usually takes a few seconds.")
                .appBody(14)
                .foregroundStyle(AppColor.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            if let problem {
                Text(problem)
                    .appBody(14, weight: .semibold)
                    .foregroundStyle(AppColor.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .padding(.top, 24)
                    .accessibilityLabel("Checking iCloud")
            }

            if offersContinue || problem != nil {
                VStack(spacing: 8) {
                    PrimaryButton(title: "Continue", action: onContinue)
                    Text("Anything still on its way will appear by itself.")
                        .appBody(12)
                        .foregroundStyle(AppColor.placeholder)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 28)
                .transition(.opacity)
            }

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColor.background)
        .animation(.easeOut(duration: 0.2), value: offersContinue)
        .animation(.easeOut(duration: 0.2), value: problem)
        .task {
            // Signed out of iCloud: there is nothing to wait for, and this
            // answer is what takes the screen away (`isAwaitingInitialImport`).
            await cloud.refreshAccountStatus()
            try? await Task.sleep(for: .seconds(6))
            offersContinue = true
        }
    }
}

/// One line at the top of each tab while the diary is still arriving from
/// iCloud — after "Continue", or while a long history downloads — so an
/// empty or partial diary doesn't read as a lost one.
struct ICloudRestoreBanner: View {
    @ObservedObject private var cloud = CloudSyncStatus.shared

    var body: some View {
        let shows = AppMode.isLocal && cloud.isAwaitingInitialImport
        VStack(spacing: 0) {
            if shows { line }
        }
        .animation(.snappy(duration: 0.25), value: shows)
    }

    private var line: some View {
        // The server's offline banner's shape, so the two read as one kind
        // of notice.
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text("Bringing your diary back from iCloud…")
                .appBody(12, weight: .semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(AppColor.secondaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 28)
        .background(AppColor.surface, in: Capsule())
        .overlay(Capsule().stroke(AppColor.hairline, lineWidth: 1))
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

#Preview {
    ICloudRestoreView(cloud: CloudSyncStatus.shared) {}
}
