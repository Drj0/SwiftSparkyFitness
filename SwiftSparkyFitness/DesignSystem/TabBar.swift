//
//  TabBar.swift
//  SwiftSparkyFitness
//
//  The 4-tab bar (Today, Diary, Progress, Settings) from the design. Each
//  tab is the design's "ringed icon" language — a stroked circle with a
//  meaning-specific glyph inside — recreated with SF Symbols rather than
//  hand-transcribing the mockup's raw SVG paths (native icons > custom
//  Bezier art for the same shape). The design also draws a fake home
//  indicator bar under the tabs; that's the OS's own home indicator on a
//  real device, so it's omitted here to avoid a duplicate.
//

import SwiftUI

enum AppTab: CaseIterable {
    case today, diary, progress, settings

    var label: String {
        switch self {
        case .today: return "Today"
        case .diary: return "Diary"
        case .progress: return "Progress"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .today: return "sunrise"
        case .diary: return "list.bullet"
        case .progress: return "chart.line.uptrend.xyaxis"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct AppTabBar: View {
    @Binding var selection: AppTab

    /// The ringed-icon treatment is the design's, so it scales with Dynamic
    /// Type rather than staying a fixed 25pt while its glyph and label grow.
    @ScaledMetric(relativeTo: .caption2) private var ringSize: CGFloat = 25
    @ScaledMetric(relativeTo: .caption2) private var glyphSize: CGFloat = 11
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button {
                    if selection != tab {
                        Haptics.selection()
                        selection = tab
                    }
                } label: {
                    VStack(spacing: 3) {
                        ZStack {
                            Circle()
                                .stroke(color(for: tab), lineWidth: 1.9)
                                .frame(width: ringSize, height: ringSize)
                            Image(systemName: tab.symbol)
                                .font(.system(size: glyphSize, weight: .semibold))
                                .foregroundStyle(color(for: tab))
                        }
                        // At accessibility sizes the four labels can only
                        // truncate to "To…"/"Dia…", which tells the user
                        // nothing the icon doesn't. Drop to icon-only there
                        // and let VoiceOver/the large-content HUD carry the
                        // name, the way a native tab bar does.
                        if !dynamicTypeSize.isAccessibilitySize {
                            Text(tab.label)
                                .appBody(11, weight: tab == selection ? .semibold : .medium)
                                .foregroundStyle(color(for: tab))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                    }
                    // 44pt minimum touch target; the buttons were 41.3pt tall.
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                    // The glyph was its own accessibility element announcing
                    // the SF Symbol's default name — Settings read as "Edit",
                    // Today as "Sunrise". Hiding the whole label subtree and
                    // giving the Button an explicit label below is the
                    // belt-and-braces form of `children: .ignore`.
                    //
                    // Note: the simulator's hierarchy dump prints the view
                    // tree, not VoiceOver's focus order, so it still lists
                    // these children either way — this needs a real VoiceOver
                    // pass to confirm, not a dump diff.
                    .accessibilityHidden(true)
                }
                .buttonStyle(.pressable)
                // No tab ever carried the Selected trait, so VoiceOver could
                // not say which one you were on.
                .accessibilityLabel(tab.label)
                .accessibilityAddTraits(tab == selection ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 12)
        .frame(minHeight: 49)
        .background(AppColor.surface)
        .overlay(Rectangle().fill(AppColor.hairline).frame(height: 1), alignment: .top)
    }

    private func color(for tab: AppTab) -> Color {
        tab == selection ? AppColor.accent : AppColor.inactiveTab
    }
}

#Preview {
    AppTabBar(selection: .constant(.today))
}
