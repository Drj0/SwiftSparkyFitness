//
//  ProgressChartStyle.swift
//  SwiftSparkyFitness
//
//  One axis treatment for every chart on the Progress tab, so four cards
//  can't drift into four different-looking charts.
//
//  Two things this fixes that the stock axes get wrong for this app:
//  the default grid is the system separator colour, which reads visibly
//  colder than every hairline elsewhere in this warm palette (the same
//  reason `Divider()` is banned in favour of a hairline `Rectangle`); and
//  the default axis labels use the system font, where everything else here
//  is the bundled Work Sans.
//

import SwiftUI
import Charts

extension View {
    /// Applies the tab's shared axis styling, with an x-axis tick count
    /// chosen from how wide the range is — a 90-day chart labelled every day
    /// is unreadable, and a 7-day chart labelled monthly says nothing.
    func progressChartAxes(range: ProgressDateRange) -> some View {
        modifier(ProgressChartAxes(range: range))
    }
}

/// Caps how far axis labels scale with Dynamic Type.
///
/// The app scales text everywhere else, and should. Axis labels are the
/// exception: the plot area doesn't grow with the type size, so at AX 3 a
/// date label truncated to "25…" and a month of chart carried four of them —
/// strictly less information than at the default size, which is the opposite
/// of what the setting is for. Caught by rendering the card at AX 3, not by
/// reading the code.
///
/// The labels still scale, just only up to `.large`; the numbers and prose
/// around them keep scaling all the way. Anyone who needs the values rather
/// than the shape has VoiceOver, where every mark carries its own date and
/// value.
private struct AxisLabelScaling: ViewModifier {
    func body(content: Content) -> some View {
        content.dynamicTypeSize(...DynamicTypeSize.large)
    }
}

private struct ProgressChartAxes: ViewModifier {
    let range: ProgressDateRange

    /// Roughly five or six labels across, whatever the span.
    private var strideDays: Int {
        let days = range.dayCount
        switch days {
        case ..<9: return 1
        case ..<22: return 3
        case ..<46: return 7
        case ..<100: return 14
        case ..<220: return 30
        default: return 60
        }
    }

    func body(content: Content) -> some View {
        content
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: strideDays)) { value in
                    AxisGridLine().foregroundStyle(AppColor.hairline)
                    AxisTick().foregroundStyle(AppColor.hairline)
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(.dateTime.day().month(.abbreviated)))
                                .appBody(10)
                                .foregroundStyle(AppColor.secondaryText)
                                .modifier(AxisLabelScaling())
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(AppColor.hairline)
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(Self.axisLabel(number))
                                .appBody(10)
                                .foregroundStyle(AppColor.secondaryText)
                                .modifier(AxisLabelScaling())
                        }
                    }
                }
            }
            .chartXScale(domain: range.start...chartUpperBound)
    }

    /// Charts are bucketed by day, so a bar sitting on the final day needs
    /// the domain to extend past it or it renders clipped at the edge.
    private var chartUpperBound: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: range.end) ?? range.end
    }

    /// Axis numbers are tight on space, so thousands are abbreviated — but
    /// only when the value really is a round thousand, since "1.5k" for a
    /// weight axis would be absurd.
    static func axisLabel(_ value: Double) -> String {
        if abs(value) >= 1000 {
            let thousands = value / 1000
            return thousands == thousands.rounded()
                ? "\(Int(thousands))k"
                : String(format: "%.1fk", thousands)
        }
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%.1f", value)
    }
}
