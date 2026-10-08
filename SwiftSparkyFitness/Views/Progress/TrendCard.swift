//
//  TrendCard.swift
//  SwiftSparkyFitness
//
//  The shared chrome every Progress card sits in, and the pieces each card
//  builds its top half from.
//
//  The card recipe (surface + hairline overlay + clip) is the one
//  `DailySummaryCard` and `BodyCard` already use, repeated here rather than
//  generalised into a modifier because those two predate this and changing
//  them is Module 1-5 territory.
//
//  HIERARCHY
//  ---------
//  Every card reads the same way, top to bottom: what it is (a tinted
//  symbol and a small-caps name, the way Health labels a category), the one
//  number that answers it, a line of context, then the chart. The number
//  used to be a 17pt figure tucked top-right beside a 15pt title, so the
//  eye had nowhere to land first; it is now the largest thing on the card.
//  Scrubbing a chart swaps that number for the day under the finger instead
//  of floating a tooltip over the marks, so nothing is ever covered.
//

import SwiftUI

/// Which card, and what identifies it at a glance.
enum TrendKind {
    case weight, nutrition, exercise, measurements

    var title: String {
        switch self {
        case .weight: return "Weight"
        case .nutrition: return "Nutrition"
        case .exercise: return "Exercise"
        case .measurements: return "Measurements"
        }
    }

    /// The same glyphs Today's Log sheet uses for the same four things.
    var symbol: String {
        switch self {
        case .weight: return "scalemass.fill"
        case .nutrition: return "fork.knife"
        case .exercise: return "figure.run"
        case .measurements: return "ruler.fill"
        }
    }

    /// Graphic-weight colours: used for the symbol and the marks, never for
    /// text, since the pink and blue don't reach 4.5:1 on white.
    var tint: Color {
        switch self {
        case .weight: return AppColor.accent
        case .nutrition: return AppColor.accent
        case .exercise: return AppColor.energyGraphic
        case .measurements: return AppColor.water
        }
    }
}

/// A card's one shortcut — logging into it, from where you're reading it.
struct TrendCardAction {
    let label: String
    let perform: () -> Void
}

struct TrendCard<Content: View>: View {
    let kind: TrendKind
    var action: TrendCardAction?
    @ViewBuilder var content: Content

    @ScaledMetric(relativeTo: .caption) private var symbolSize: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
        }
        .padding(AppSpacing.cardPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: kind.symbol)
                .font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(kind.tint)
                .accessibilityHidden(true)
            Text(kind.title)
                .appBody(12, weight: .semibold)
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(AppColor.secondaryText)
                // A rotor stop per card, so VoiceOver can jump between them.
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let action {
                // Today's meal "+": a 28pt glyph on a 44pt target, with the
                // growth handed back so the header keeps its height.
                // In the card's own colour: a pink "+" on the blue
                // measurements card read as belonging to something else.
                Button(action: action.perform) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(kind.tint)
                        .frame(width: 28, height: 28)
                        .background(kind.tint.opacity(0.14), in: Circle())
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                        .padding(.vertical, -8)
                        .padding(.trailing, -8)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(action.label)
            }
        }
        .frame(minHeight: 28)
    }
}

/// The card's answer: a small label saying what the number is, the number
/// itself in the display face, and a line of context under it.
struct TrendHeadline: View {
    /// "Latest", "Daily average", or — while scrubbing — the day under the
    /// finger.
    let eyebrow: String
    let value: String
    var unit: String?
    var detail: Text?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(eyebrow)
                .appBody(12)
                .foregroundStyle(AppColor.secondaryText)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .appDisplay(30)
                    .foregroundStyle(AppColor.ink)
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit)
                        .appBody(15, weight: .semibold)
                        .foregroundStyle(AppColor.secondaryText)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            if let detail {
                detail
                    .appBody(13)
                    .foregroundStyle(AppColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: value)
        // One stop: "Latest, 79.3 kg, down 2.7 kg since 1 Sep".
        .accessibilityElement(children: .combine)
    }
}

/// What a card shows when the range holds nothing to chart.
///
/// Deliberately not an error: an empty range is a normal answer for a new
/// account or a quiet week, and dressing it as a failure would send people
/// looking for a problem that isn't there. Where the card can be logged
/// into, the fix is offered right there.
struct TrendEmptyState: View {
    let message: String
    var action: TrendCardAction?
    /// The card's colour, for the button's glyph and fill. The label stays
    /// ink: the blue and green don't reach 4.5:1 as text.
    var tint: Color = AppColor.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message)
                .appBody(14)
                .foregroundStyle(AppColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action: action.perform) {
                    Label {
                        Text(action.label).foregroundStyle(AppColor.ink)
                    } icon: {
                        Image(systemName: "plus").foregroundStyle(tint)
                    }
                    .appBody(14, weight: .semibold)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(tint.opacity(0.14), in: Capsule())
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

/// A row of small figures under a chart, split by hairlines, collapsing to
/// a column when large text won't fit them side by side.
struct TrendStatRow: View {
    struct Item: Identifiable {
        let value: String
        let label: String
        var id: String { label }
    }

    let items: [Item]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Rectangle()
                            .fill(AppColor.hairline)
                            .frame(width: 1)
                            .padding(.vertical, 4)
                    }
                    stat(item)
                        .frame(maxWidth: .infinity)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    stat(item)
                }
            }
        }
    }

    private func stat(_ item: Item) -> some View {
        VStack(spacing: 2) {
            Text(item.value)
                .appBody(15, weight: .semibold)
                .foregroundStyle(AppColor.ink)
                .lineLimit(1)
            Text(item.label)
                .appBody(11)
                .foregroundStyle(AppColor.secondaryText)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.label): \(item.value)")
    }
}

/// A selectable capsule, for the pickers inside cards.
struct TrendChip: View {
    let title: String
    let isSelected: Bool
    /// Set inside a Progress card: the selection then takes the card's
    /// colour as a soft fill and ring, the same as Nutrition's tiles, since
    /// white text on the lighter tints fails contrast. Nil keeps the solid
    /// accent capsule.
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .appBody(13, weight: .semibold)
                .foregroundStyle(isSelected ? (tint == nil ? .white : AppColor.ink) : AppColor.secondaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(selectedFill, in: Capsule())
                .overlay(Capsule().stroke(isSelected ? tint ?? .clear : .clear, lineWidth: 1.5))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var selectedFill: Color {
        guard isSelected else { return AppColor.inputBackground }
        return tint?.opacity(0.14) ?? AppColor.accent
    }
}

/// "↓ 2.7 kg since 1 Sep" — the arrow carries the direction, the ink stays
/// neutral: down is not universally good, since someone can be gaining on
/// purpose.
func changeDetail(_ change: Double, unit: String, since date: String, format: (Double) -> String) -> Text {
    let symbol = change > 0 ? "arrow.up.right" : (change < 0 ? "arrow.down.right" : "arrow.right")
    let spoken = change > 0 ? "up" : (change < 0 ? "down" : "no change,")
    return Text("\(Image(systemName: symbol)) \(format(abs(change))) \(unit) since \(date)")
        .accessibilityLabel("\(spoken) \(format(abs(change))) \(unit) since \(date)")
}

// MARK: - Chart selection

/// Scrubbing snaps to the reading nearest the finger. Marks plotted with a
/// `.day` unit sit mid-day, so distances are measured from noon.
func nearestPoint(_ points: [BodyTrendPoint], to date: Date) -> BodyTrendPoint? {
    points.min {
        abs($0.date.addingTimeInterval(43_200).timeIntervalSince(date))
            < abs($1.date.addingTimeInterval(43_200).timeIntervalSince(date))
    }
}

/// The bucket start a raw chart position falls in: its day, or its week.
func bucketStart(of date: Date, _ granularity: TrendGranularity) -> Date {
    let calendar = Calendar.current
    switch granularity {
    case .day: return calendar.startOfDay(for: date)
    case .week: return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }
}
