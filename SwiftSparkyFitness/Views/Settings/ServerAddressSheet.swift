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
    /// "Sparky Server" when editing an address that's already in use;
    /// "Connect to Sparky Server" when this is the step that joins one.
    var title: String = "Sparky Server"
    /// "Save" when editing, "Connect" when joining. The override variant is
    /// built from this, so a failed probe offers "Connect anyway".
    var saveTitle: String = "Save"
    /// Shown under the field. Carries the consequence of the action the sheet
    /// is about to take — which is why local mode's "your on-device data
    /// stays here" paragraph lives here now instead of sitting permanently in
    /// Settings, explaining a switch nobody had touched yet.
    var note: String? = nil
    var onSaved: () -> Void = {}

    /// Why an address wasn't accepted. The two kinds are not interchangeable:
    /// a malformed address can never be stored, while one that merely didn't
    /// answer can be stored anyway, because the server may just be off right
    /// now. Keeping them in one type stops the button offering an override the
    /// save path would refuse.
    enum Problem: Equatable {
        case malformed
        case unreachable(host: String)
        case notSparkyFitness(host: String)

        var message: String {
            switch self {
            case .malformed:
                return "That doesn't look like a web address — it should start with http:// and name your server."
            case .unreachable(let host):
                // Not "check you're on the same network", which assumed the
                // server sits on the phone's LAN — true for a box at home,
                // false for a VPS or anything behind a domain.
                return "Couldn't reach \(host). Check the server is running and that this phone can reach it."
            case .notSparkyFitness(let host):
                return "\(host) answered, but it doesn't look like a SparkyFitness server. Check the port — the server usually runs on 3010."
            }
        }

        /// A failed probe is advisory. A malformed address is not.
        var allowsOverride: Bool { self != .malformed }
    }

    @AppStorage(ServerConfig.defaultsKey) private var serverURL = ""
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var isChecking = false
    @State private var problem: Problem?
    @FocusState private var isFocused: Bool

    private var offersOverride: Bool { problem?.allowsOverride == true }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: title,
                onCancel: { dismiss() },
                action: SheetAction(
                    offersOverride ? "\(saveTitle) anyway" : saveTitle,
                    isBusy: isChecking,
                    perform: save
                )
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // The field draws its own error text and border, so the
                    // message goes through it rather than a second red label.
                    AppTextField(
                        placeholder: ServerConfig.placeholder,
                        text: $draft,
                        style: .filled,
                        errorMessage: problem?.message,
                        keyboardType: .URL,
                        submitLabel: .done,
                        focus: $isFocused
                    )
                    .onSubmit(save)

                    // One line, and nothing about where the server runs.
                    //
                    // This used to open with "On a Mac, run `scutil --get
                    // LocalHostName`…" and a note about Bonjour names beating
                    // DHCP leases, then insist the phone be on the same
                    // network. All of it was this project's own dev setup
                    // written up as instructions: a SparkyFitness server is
                    // just as often a Linux box, a NAS, a VPS or a domain
                    // behind a reverse proxy — none of which are on the
                    // phone's LAN, and none of which have `scutil`.
                    //
                    // What every one of those cases shares is the address you
                    // already use to reach it, so that's all this asks for.
                    Text("The address you'd open in a browser, including the port — SparkyFitness usually runs on 3010.")
                        .appBody(12)
                        .foregroundStyle(AppColor.placeholder)
                        .fixedSize(horizontal: false, vertical: true)

                    if let note {
                        Text(note)
                            .appBody(12)
                            .foregroundStyle(AppColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
                .padding(18)
            }
        }
        .background(AppColor.surface)
        .task {
            draft = ServerConfig.isUnconfigured ? "" : ServerConfig.urlString
            isFocused = true
        }
        // Editing after a failed check is a new address, so it earns a fresh
        // check rather than inheriting the previous one's "Save anyway".
        .onChange(of: draft) { _, _ in problem = nil }
    }

    /// Checks the address reaches a SparkyFitness server before saving it,
    /// because the alternative — accepting any string and failing at the next
    /// request — surfaces as a timeout on the offline screen, indistinguishable
    /// from a server that's merely down.
    ///
    /// A failed check *warns* rather than blocks, and a second tap saves
    /// regardless. Blocking would rebuild the trap this sheet exists to fix:
    /// if the server happens to be off while the user is correcting a typo,
    /// a mandatory probe would refuse the very address that fixes the app, and
    /// this screen is the last one standing when nothing else can load.
    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.host != nil else {
            // Deliberately before the override check: no number of taps can
            // store an address the app could never build a request from.
            problem = .malformed
            Haptics.error()
            return
        }
        if offersOverride {
            commit(trimmed)
            return
        }
        Task {
            isChecking = true
            let verdict = await ServerProbe.check(url)
            isChecking = false

            let host = url.host ?? trimmed
            switch verdict {
            case .reachable:
                commit(trimmed)
            case .unreachable:
                problem = .unreachable(host: host)
                Haptics.error()
            case .notSparkyFitness:
                problem = .notSparkyFitness(host: host)
                Haptics.error()
            }
        }
    }

    private func commit(_ address: String) {
        serverURL = address
        Haptics.success()
        dismiss()
        onSaved()
    }
}
