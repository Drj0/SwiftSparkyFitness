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
//  The value axis sits on the trailing edge, as in Health: the eye enters a
//  chart from the left at the oldest data, and a column of numbers there
//  pushed the first day's mark away from the card edge it lines up with.
//

import SwiftUI
import Charts

extension View {
    /// Applies the tab's shared axis styling, with x-axis labels chosen from
    /// how wide the range is — a 90-day chart labelled every day is
    /// unreadable, and a 7-day chart labelled monthly says nothing.
    ///
    /// `granularity` is the bucketing of the marks being drawn: weekly bars
    /// need the domain widened to whole weeks, or the first and last weeks
    /// render clipped at the edges. Line charts always pass `.day`.
    func progressChartAxes(range: ProgressDateRange, granularity: TrendGranularity = .day) -> some View {
        modifier(ProgressChartAxes(range: range, granularity: granularity))
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
    let granularity: TrendGranularity

    /// Roughly five to seven labels across, whatever the span.
    private enum Labels {
        /// A week: one label per day, by weekday — "Tue" says more about a
        /// week than "24 Sep" does.
        case weekdays
        case days(every: Int)
        case months(every: Int)
    }

    private var labels: Labels {
        switch range.dayCount {
        case ..<9: return .weekdays
        case ..<22: return .days(every: 3)
        case ..<46: return .days(every: 7)
        case ..<100: return .days(every: 14)
        case ..<220: return .months(every: 1)
        default: return .months(every: 2)
        }
    }

    func body(content: Content) -> some View {
        content
            .chartXAxis {
                switch labels {
                case .weekdays:
                    AxisMarks(values: .stride(by: .day)) { value in
                        xMark(value, format: .dateTime.weekday(.abbreviated))
                    }
                case .days(let every):
                    AxisMarks(values: .stride(by: .day, count: every)) { value in
                        xMark(value, format: .dateTime.day().month(.abbreviated))
                    }
                case .months(let every):
                    AxisMarks(values: .stride(by: .month, count: every)) { value in
                        xMark(value, format: .dateTime.month(.abbreviated))
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
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
            .chartXScale(domain: domain)
    }

    @AxisMarkBuilder
    private func xMark(_ value: AxisValue, format: Date.FormatStyle) -> some AxisMark {
        AxisGridLine().foregroundStyle(AppColor.hairline)
        AxisTick().foregroundStyle(AppColor.hairline)
        AxisValueLabel {
            if let date = value.as(Date.self) {
                Text(date.formatted(format))
                    .appBody(10)
                    .foregroundStyle(AppColor.secondaryText)
                    .modifier(AxisLabelScaling())
            }
        }
    }

    /// Charts are bucketed by day, so a bar sitting on the final day needs
    /// the domain to extend past it or it renders clipped at the edge. Weekly
    /// bars need the same at week granularity.
    private var domain: ClosedRange<Date> {
        let calendar = Calendar.current
        switch granularity {
        case .day:
            let upper = calendar.date(byAdding: .day, value: 1, to: range.end) ?? range.end
            return range.start...upper
        case .week:
            let lower = calendar.dateInterval(of: .weekOfYear, for: range.start)?.start ?? range.start
            let upper = calendar.dateInterval(of: .weekOfYear, for: range.end)?.end ?? range.end
            return lower...upper
        }
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

// MARK: - Scrubbing

extension View {
    /// Inspect a chart without fighting the page's scroll: tap a day to pin
    /// it (tap it again to let go), or touch and hold, then drag, to scrub.
    ///
    /// Not `chartXSelection`, and not a SwiftUI drag of any kind. Both were
    /// tried on the simulator and both kept the page from scrolling when a
    /// swipe began on a chart — a 300pt drag moved it by nothing, even with
    /// the drag sequenced behind a 0.6s hold that never fired — and the
    /// charts are most of this screen. A UIKit long press sits alongside
    /// the scroll view's own pan the way every list's long press does: a
    /// swipe scrolls, and a finger held still scrubs.
    func chartScrubbing(_ selection: Binding<Date?>, granularity: TrendGranularity = .day) -> some View {
        chartOverlay { proxy in
            GeometryReader { geometry in
                ChartScrubLayer(proxy: proxy, geometry: geometry, selection: selection, granularity: granularity)
            }
        }
    }
}

private struct ChartScrubLayer: View {
    let proxy: ChartProxy
    let geometry: GeometryProxy
    @Binding var selection: Date?
    let granularity: TrendGranularity

    /// When the last hold lifted. A tap can land as a hold lifts, and it
    /// mustn't un-pin the day the scrub just stopped on; a time window
    /// rather than a flag, so a tap that never arrives can't swallow the
    /// next real one.
    @State private var scrubEndedAt = Date.distantPast

    var body: some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .gesture(HoldToScrub { location in
                if let location {
                    selection = date(at: location.x)
                } else {
                    scrubEndedAt = Date()
                }
            })
            .onTapGesture(coordinateSpace: .local) { location in
                guard Date().timeIntervalSince(scrubEndedAt) > 0.3,
                      let tapped = date(at: location.x) else { return }
                if let current = selection,
                   bucketStart(of: current, granularity) == bucketStart(of: tapped, granularity) {
                    selection = nil
                } else {
                    selection = tapped
                }
            }
            // VoiceOver reads the marks themselves; this layer only catches
            // touches.
            .accessibilityHidden(true)
    }

    /// The date under an x position in the overlay, clamped to the plot.
    private func date(at x: CGFloat) -> Date? {
        guard let plot = proxy.plotFrame else { return nil }
        let frame = geometry[plot]
        let clamped = min(max(x, frame.minX), frame.maxX)
        return proxy.value(atX: clamped - frame.minX, as: Date.self)
    }
}

/// A long press that keeps reporting the finger while it moves.
private struct HoldToScrub: UIGestureRecognizerRepresentable {
    /// The finger's position in the layer while held; nil when it lifts.
    let onChange: (CGPoint?) -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        // Long enough that a resting thumb mid-scroll doesn't grab a day,
        // short enough to feel like touching the chart.
        recognizer.minimumPressDuration = 0.3
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed: onChange(context.converter.localLocation)
        default: onChange(nil)
        }
    }
}
