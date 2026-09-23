//
//  ServerAddressSheet.swift
//  SwiftSparkyFitness
//
//  Editing the backend address, reachable from Settings *and* from the
//  can't-reach-the-server screen.
//
//  The second one matters: once the address stopped being hardcoded, a fresh
//  install starts on the placeholder, fails to connect, and lands on the
//  offline screen — which only offered "Try again". No connection means no
//  sign-in, no sign-in means no tab bar, and no tab bar means no Settings, so
//  the one field that could fix it was unreachable. Hit live on a physical
//  device. Anything that can strand the user needs an escape hatch on the
//  screen where they're stranded.
//

import SwiftUI

struct ServerAddressSheet: View {
    var onSaved: () -> Void = {}

    @AppStorage(ServerConfig.defaultsKey) private var serverURL = ""
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: "Server",
                onCancel: { dismiss() },
                action: SheetAction("Save", perform: save)
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Where is your SparkyFitness server?")
                        .appBody(14, weight: .semibold)
                        .foregroundStyle(AppColor.ink)

                    AppTextField(
                        placeholder: ServerConfig.placeholder,
                        text: $draft,
                        style: .filled,
                        keyboardType: .URL,
                        submitLabel: .done,
                        focus: $isFocused
                    )
                    .onSubmit(save)

                    Text("On a Mac, run `scutil --get LocalHostName` and use `http://<that>.local:3010`. The Bonjour name is stabler than the IP, which changes on every DHCP renewal.")
                        .appBody(12)
                        .foregroundStyle(AppColor.placeholder)

                    Text("Your phone has to be on the same network as the server.")
                        .appBody(12)
                        .foregroundStyle(AppColor.placeholder)
                }
                .padding(18)
            }
        }
        .background(AppColor.surface)
        .task {
            draft = ServerConfig.isUnconfigured ? "" : ServerConfig.urlString
            isFocused = true
        }
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.host != nil else {
            Haptics.error()
            return
        }
        serverURL = trimmed
        Haptics.success()
        dismiss()
        onSaved()
    }
}
