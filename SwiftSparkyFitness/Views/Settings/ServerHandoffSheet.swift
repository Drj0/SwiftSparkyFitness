//
//  ServerHandoffSheet.swift
//  SwiftSparkyFitness
//
//  "Bring this iPhone's diary to your server?" — shown once after signing in
//  to a server from this device's diary, and from Settings until answered.
//

import SwiftUI

struct ServerHandoffSheet: View {
    @StateObject private var model: ServerHandoffModel
    @Environment(\.dismiss) private var dismiss

    init(user: SessionUser) {
        _model = StateObject(wrappedValue: ServerHandoffModel(user: user))
    }

    var body: some View {
        VStack(spacing: 16) {
            content
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColor.surface)
        .task { await model.prepare() }
        // Nothing to send closes by itself: there was nothing to decide.
        .onChange(of: model.phase) { _, phase in
            if case .finished(let report) = phase, report.sent == 0, report.failures.isEmpty, report.deleted == 0 {
                dismiss()
            }
        }
        .interactiveDismissDisabled(isSending)
    }

    private var isSending: Bool {
        if case .sending = model.phase { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .checking:
            ProgressView().tint(AppColor.accent)
            caption("Checking \(model.serverHost)…")

        case .ready(let plan, let warning):
            title("Bring this iPhone's diary to your server?")
            body(summary(plan))
            if plan.needsConfirmation {
                body("That includes deleting \(plan.deletes) entries from the server — more than usual. Only continue if you deleted them on this iPhone on purpose.", color: AppColor.destructive)
            }
            if let warning { body(warning, color: AppColor.destructive) }
            PrimaryButton(title: "Send to server") { Task { await model.send() } }
            HStack(spacing: 24) {
                secondary("Not now") { dismiss() }
                secondary("Don't send") {
                    model.decline()
                    dismiss()
                }
            }

        case .sending(let done, let total):
            title("Sending your diary")
            if total > 0 {
                ProgressView(value: Double(done), total: Double(total)).tint(AppColor.accent)
                caption("\(done) of \(total)").monospacedDigit()
            } else {
                ProgressView().tint(AppColor.accent)
            }
            caption("Keep the app open until it finishes. If it's interrupted, nothing is sent twice.")

        case .finished(let report):
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(AppColor.accent)
                .accessibilityHidden(true)
            title("Your diary is on the server")
            body(finishedSummary(report))
            PrimaryButton(title: "Done") { dismiss() }

        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(AppColor.destructive)
                .accessibilityHidden(true)
            title("Couldn't finish sending")
            body(message)
            PrimaryButton(title: "Try again") { Task { await model.prepare() } }
            secondary("Close") { dismiss() }
        }
    }

    private func summary(_ plan: ServerPush.Plan) -> String {
        var parts: [String] = []
        if plan.creates > 0 { parts.append("\(plan.creates) new") }
        if plan.updates > 0 { parts.append("\(plan.updates) updated") }
        if plan.deletes > 0 { parts.append("\(plan.deletes) deleted") }
        let what = parts.joined(separator: ", ")
        return "\(what) items from this iPhone go to \(model.serverHost). Nothing already on the server is removed unless you deleted it here, and this iPhone keeps its copy."
    }

    private func finishedSummary(_ report: ServerPush.Report) -> String {
        let sent = "Sent \(report.sent) item\(report.sent == 1 ? "" : "s")."
        guard !report.failures.isEmpty else { return sent + " This iPhone keeps its copy." }
        let first = report.failures.first?.message ?? ""
        return sent + " \(report.failures.count) couldn't be sent (\(first)). They stay on this iPhone and you can send again from Settings."
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .appBody(17, weight: .semibold)
            .foregroundStyle(AppColor.ink)
            .multilineTextAlignment(.center)
    }

    private func body(_ text: String, color: Color = AppColor.secondaryText) -> some View {
        Text(text)
            .appBody(13)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .appBody(12)
            .foregroundStyle(AppColor.placeholder)
            .multilineTextAlignment(.center)
    }

    private func secondary(_ text: String, action: @escaping () -> Void) -> some View {
        Button(text, action: action)
            .appBody(15, weight: .semibold)
            .foregroundStyle(AppColor.accent)
            .frame(minHeight: 44)
    }
}
