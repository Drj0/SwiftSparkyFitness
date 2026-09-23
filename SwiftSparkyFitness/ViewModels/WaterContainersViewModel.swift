//
//  WaterContainersViewModel.swift
//  SwiftSparkyFitness
//
//  The vessels a quick-add can log. See WaterContainer for the key fact:
//  setting a primary changes nothing on its own, because the server doesn't
//  consult it — the app has to send `container_id`.
//

import Foundation
import Combine

@MainActor
final class WaterContainersViewModel: ObservableObject {
    @Published private(set) var containers: [WaterContainer] = []
    @Published private(set) var isLoading = false
    @Published private(set) var busyContainerId: Int?
    @Published var errorMessage: String?

    @Published var newName = ""
    @Published var newVolume = ""
    @Published private(set) var isCreating = false

    private let apiClient: APIClientProtocol

    init(apiClient: APIClientProtocol = APIClient.shared) {
        self.apiClient = apiClient
    }

    var parsedVolume: Double? {
        let raw = newVolume.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(raw), value > 0, value <= 9999 else { return nil }
        return value
    }

    var canCreate: Bool {
        !newName.trimmingCharacters(in: .whitespaces).isEmpty && parsedVolume != nil && !isCreating
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            containers = try await apiClient.waterContainers()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The first container someone adds becomes primary, otherwise adding one
    /// would appear to do nothing until they also tapped "Use this".
    func create() async {
        guard let volume = parsedVolume else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }
        do {
            let isFirst = containers.isEmpty
            let created = try await apiClient.createWaterContainer(
                WaterContainerInput(name: name, volume: volume)
            )
            if isFirst {
                try? await apiClient.setPrimaryWaterContainer(id: created.id)
            }
            newName = ""
            newVolume = ""
            Haptics.success()
            await load()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    func setPrimary(_ container: WaterContainer) async {
        busyContainerId = container.id
        errorMessage = nil
        defer { busyContainerId = nil }
        do {
            try await apiClient.setPrimaryWaterContainer(id: container.id)
            Haptics.selection()
            await load()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    func delete(_ container: WaterContainer) async {
        busyContainerId = container.id
        errorMessage = nil
        defer { busyContainerId = nil }
        do {
            try await apiClient.deleteWaterContainer(id: container.id)
            Haptics.warning()
            await load()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }
}
