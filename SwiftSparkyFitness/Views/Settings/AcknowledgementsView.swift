//
//  AcknowledgementsView.swift
//  SwiftSparkyFitness
//
//  Where the app's food and exercise data comes from. Open Food Facts'
//  licence (ODbL) requires the attribution; the others are credited because
//  the app would be much thinner without them.
//

import SwiftUI

struct AcknowledgementsView: View {
    private struct Source: Identifiable {
        let name: String
        let detail: String
        let url: URL
        var id: String { name }
    }

    private let sources = [
        Source(
            name: "Open Food Facts",
            detail: "Packaged and branded foods. Data available under the Open Database License (ODbL).",
            url: URL(string: "https://world.openfoodfacts.org")!
        ),
        Source(
            name: "Indian Nutrient Databank (INDB)",
            detail: "Nutrition for Indian dishes, by household serving.",
            url: URL(string: "https://www.anuvaad.org.in/indian-nutrient-databank/")!
        ),
        Source(
            name: "USDA FoodData Central",
            detail: "Generic foods, through a SparkyFitness server.",
            url: URL(string: "https://fdc.nal.usda.gov")!
        ),
        Source(
            name: "Free Exercise DB",
            detail: "Exercises and their photos. Public domain.",
            url: URL(string: "https://github.com/yuhonas/free-exercise-db")!
        ),
        Source(
            name: "SparkyFitness",
            detail: "The open-source, self-hosted server this app can sync with.",
            url: URL(string: "https://github.com/CodeWithCJ/SparkyFitness")!
        ),
    ]

    var body: some View {
        List {
            Section {
                ForEach(sources) { source in
                    Link(destination: source.url) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.name)
                                .appBody(15, weight: .semibold)
                                .foregroundStyle(AppColor.ink)
                            Text(source.detail)
                                .appBody(12)
                                .foregroundStyle(AppColor.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                    }
                    .accessibilityHint("Opens the website")
                }
            }
            .listRowBackground(AppColor.surface)
            .listRowSeparatorTint(AppColor.hairline)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppColor.background)
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { AcknowledgementsView() }
}
