//
//  BodyCard.swift
//  SwiftSparkyFitness
//
//  Today's weight stub ("Log today's →", which went nowhere) made real.
//  Shows the day's check-in row: the weight as the headline, any logged
//  measurements as chips beneath it. Because a day holds exactly one
//  check-in row, this is never a list — it's either the day's numbers or
//  the prompt to add them.
//

import SwiftUI

struct BodyCard: View {
    let measurements: BodyMeasurements
    let preferences: UserPreferences
    let onLogWeight: () -> Void
    let onLogMeasurements: () -> Void

    private var otherFields: [(field: BodyField, value: Double)] {
        measurements.populatedFields.filter { $0.field != .weight }
    }

    private var chipsAccessibilityValue: String {
        otherFields.map { chipText($0.field, $0.value) }.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Weight")
                    .appBody(12, weight: .semibold)
                    .foregroundStyle(AppColor.secondaryText)
                    .textCase(.uppercase)
                Spacer()
                Button(action: onLogMeasurements) {
                    Text(otherFields.isEmpty ? "+ Measurements" : "Edit")
                        .appBody(12, weight: .semibold)
                        .foregroundStyle(AppColor.accent)
                        // A 14pt line of text was a 14pt target. Padding the
                        // hit area out and subtracting the same amount back
                        // grows only what's tappable — the label keeps its
                        // position and the header its height, which a
                        // `.frame(minWidth:)` couldn't promise for two labels
                        // of different widths.
                        //
                        // Lopsided on purpose: upwards it uses the card's own
                        // padding, downwards it reaches over the weight
                        // button. The label measures 11.7pt, not the 14 its
                        // point size suggests, so 14 + 11.7 + 19 clears 44.
                        //
                        // That overlap used to be why this stopped at 34pt:
                        // the weight button is a later sibling, so it drew on
                        // top and took the taps. The header carries a zIndex
                        // now, which reorders hit-testing without reordering
                        // layout — and the region they share is the top-right
                        // corner, where this button's own label is and where
                        // the weight value (left-aligned) never reaches.
                        // 13, not 12: the short "Edit" label left the target
                        // 43pt wide, a point under the minimum.
                        .padding(.horizontal, 13)
                        .padding(.top, 14)
                        .padding(.bottom, 19)
                        .contentShape(Rectangle())
                        .padding(.horizontal, -13)
                        .padding(.top, -14)
                        .padding(.bottom, -19)
                }
                .buttonStyle(.pressable)
            }
            // Above the weight button for hit-testing only; the layout is
            // unchanged. See the padding note above.
            .zIndex(1)

            Button(action: onLogWeight) {
                // Grouped only so the hit-area padding below can wrap both
                // branches at once.
                Group {
                    if let weight = measurements.weight {
                        // Was a `Text + Text` concatenation, which can't take
                        // a view modifier — and the scaling font has to be
                        // one. An HStack on .firstTextBaseline keeps the
                        // identical look (unit sitting on the number's
                        // baseline) while letting both halves scale with
                        // Dynamic Type.
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(preferences.formatted(weight))
                                .appBody(20, weight: .bold)
                                .foregroundStyle(AppColor.ink)
                            Text(" \(preferences.weightUnitLabel)")
                                .appBody(13)
                                .foregroundStyle(AppColor.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Log today's →")
                            .appBody(13, weight: .semibold)
                            .foregroundStyle(AppColor.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                // Same trick as the button above, mirrored: it takes its room
                // downwards (the chips and the card's own padding aren't
                // tappable, so nothing is stolen) and leaves the header
                // button the space above.
                .padding(.top, 4)
                .padding(.bottom, 17)
                .contentShape(Rectangle())
                .padding(.top, -4)
                .padding(.bottom, -17)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(measurements.weight == nil ? "Log today's weight" : "Weight")
            .accessibilityValue(measurements.weight.map { "\(preferences.formatted($0)) \(preferences.weightUnitLabel)" } ?? "Not logged")

            if !otherFields.isEmpty {
                // Wraps rather than scrolls: five measurements at most, and
                // a horizontal scroller inside a vertical ScrollView is a
                // gesture conflict for no benefit.
                FlowRow(spacing: 6) {
                    ForEach(otherFields, id: \.field.id) { entry in
                        chip(entry.field, entry.value)
                    }
                }
                // Five chips were five VoiceOver stops between the weight and
                // whatever follows the card; they're one list of numbers.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Measurements")
                .accessibilityValue(chipsAccessibilityValue)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppColor.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    /// Shared with the chips' accessibility value so the spoken list and the
    /// visible chips can't drift apart.
    private func chipText(_ field: BodyField, _ value: Double) -> String {
        "\(field.label) \(preferences.formatted(value))\(field.unitKind == .percent ? "%" : " \(field.unitLabel(preferences))")"
    }

    private func chip(_ field: BodyField, _ value: Double) -> some View {
        Text(chipText(field, value))
            .appBody(12)
            .foregroundStyle(AppColor.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(AppColor.inputBackground)
            .clipShape(Capsule())
    }
}

/// Minimal wrapping row — SwiftUI has no built-in "flow layout" before
/// iOS 16's Layout protocol, and this app targets the same baseline as the
/// rest of its custom controls, so it's implemented directly.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                widest = max(widest, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += rowWidth > 0 ? spacing + size.width : size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        widest = max(widest, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: min(widest, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
