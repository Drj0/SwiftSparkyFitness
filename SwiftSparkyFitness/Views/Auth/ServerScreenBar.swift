//
//  ServerScreenBar.swift
//  SwiftSparkyFitness
//
//  The strip across the top of every screen between choosing the server
//  path and being signed in: connecting, can't connect, log in, sign up.
//
//  Those screens used to have no way out. Choosing "Connect to a server"
//  stored the mode, and from then on every screen on offer needed that
//  server to answer — a wrong address, a server that was off, or simply the
//  wrong card tapped left nothing to do but delete the app. Back returns to
//  the start screen, where "On this iPhone" is one tap away; the address
//  being tried is always on show beside it, so a typo is visible before it
//  turns into a mystery timeout.
//

import SwiftUI

struct ServerScreenBar: View {
    var onBack: () -> Void
    var onEditServer: () -> Void
    /// Where Back goes, for VoiceOver: the start screen, or from sign-up,
    /// the login form.
    var backHint = "Returns to choosing how to use Sparky"

    /// Read only so the chip redraws the moment the address sheet saves. The
    /// address itself comes from ServerConfig, which also honours SERVER_URL.
    @AppStorage(ServerConfig.defaultsKey) private var serverURL = ""

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Back")
                        .appBody(16, weight: .semibold)
                }
                .foregroundStyle(AppColor.accent)
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityHint(backHint)

            Spacer(minLength: 8)

            Button(action: onEditServer) {
                HStack(spacing: 6) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 11, weight: .semibold))
                    Text(address)
                        .appBody(12, weight: .semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(AppColor.secondaryText)
                .padding(.horizontal, 12)
                .frame(minHeight: 30)
                .background(AppColor.inputBackground, in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Server, \(address)")
            .accessibilityHint("Changes the server address")
            .accessibilityAddTraits(.isButton)
        }
        .padding(.horizontal, AppSpacing.screenPad)
        .background(AppColor.background)
    }

    /// "192.168.1.20:3010" — the part of the address a person recognises.
    private var address: String {
        _ = serverURL
        if ServerConfig.isUnconfigured { return "Add server address" }
        let url = ServerConfig.url
        guard let host = url.host else { return ServerConfig.urlString }
        return url.port.map { "\(host):\($0)" } ?? host
    }
}

extension AppMode {
    /// Steps off the server path before an account is signed in, to the
    /// start screen (`nil`) or straight to this-device mode. Nothing is
    /// deleted: an address stays saved and a server copy stays on disk, so
    /// choosing the server again picks up where it was.
    @MainActor
    static func leaveServer(for next: AppMode?) {
        ServerSync.shared.deactivate(removingCopy: false)
        AppMode.current = next
        Haptics.selection()
    }
}
