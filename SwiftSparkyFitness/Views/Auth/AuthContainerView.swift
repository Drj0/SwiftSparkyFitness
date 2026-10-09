//
//  AuthContainerView.swift
//  SwiftSparkyFitness
//
//  The sign-in screen, with Back and the server address above it.
//
//  There is no sign-up here: accounts are made on the server's own web app,
//  where its admin manages them — and deleted there too. An app that creates
//  accounts must also delete them (App Store guideline 5.1.1(v)), and the
//  server is where both belong.
//

import SwiftUI

struct AuthContainerView: View {
    @ObservedObject var viewModel: AuthViewModel
    @State private var isEditingServer = false

    var body: some View {
        LoginView(viewModel: viewModel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColor.background)
            .safeAreaInset(edge: .top, spacing: 0) {
                ServerScreenBar(
                    onBack: { AppMode.leaveServer(for: nil) },
                    onEditServer: { isEditingServer = true },
                    backHint: "Returns to choosing how to use Sparky"
                )
            }
            .sheet(isPresented: $isEditingServer) {
                ServerAddressSheet()
                    .fittedDetent()
                    .presentationDragIndicator(.visible)
            }
    }
}
