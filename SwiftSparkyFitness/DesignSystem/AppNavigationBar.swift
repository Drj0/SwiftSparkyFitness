//
//  AppNavigationBar.swift
//  SwiftSparkyFitness
//
//  Makes a real `NavigationStack` wear the app's own typeface.
//
//  Settings is the first screen here built on a navigation stack rather than
//  a hand-rolled header, which buys the large title, the back button, the
//  interactive back-swipe and the title's collapse-on-scroll for free. What
//  it doesn't buy is the design's serif: a `navigationTitle` renders in San
//  Francisco, so without this the one screen with a system title would be the
//  only place in the app where a heading isn't Newsreader.
//
//  There is no SwiftUI API for the bar's font, so it goes through
//  `UINavigationBarAppearance`, applied once at launch. Both faces are
//  wrapped in `UIFontMetrics` because a nav bar does NOT scale a custom font
//  with Dynamic Type on its own — the rest of the app scales (see AppFont),
//  and a title that stayed 34pt while everything under it grew would look
//  like a bug.
//
//  `UIFont(name:)` returns nil if a face isn't registered, so a missing font
//  leaves the system default rather than crashing — the same quiet degradation
//  `Font.custom` gives everywhere else.
//

import SwiftUI
import UIKit

enum AppNavigationBar {
    static func apply() {
        let ink = UIColor(AppColor.ink)

        let standard = UINavigationBarAppearance()
        standard.configureWithDefaultBackground()
        standard.titleTextAttributes = attributes(size: 17, style: .headline, color: ink)
        standard.largeTitleTextAttributes = attributes(size: 30, style: .largeTitle, color: ink)

        // Transparent at the top of a scroll so the screen's own warm
        // background runs under the bar; the default blur then fades in as
        // content slides beneath it, which is the stock behaviour.
        let atRest = UINavigationBarAppearance()
        atRest.configureWithTransparentBackground()
        atRest.titleTextAttributes = standard.titleTextAttributes
        atRest.largeTitleTextAttributes = standard.largeTitleTextAttributes

        let bar = UINavigationBar.appearance()
        bar.standardAppearance = standard
        bar.compactAppearance = standard
        bar.scrollEdgeAppearance = atRest
    }

    private static func attributes(
        size: CGFloat,
        style: UIFont.TextStyle,
        color: UIColor
    ) -> [NSAttributedString.Key: Any] {
        guard let face = UIFont(name: AppFont.Face.serifSemiBold, size: size) else {
            return [.foregroundColor: color]
        }
        return [
            .foregroundColor: color,
            .font: UIFontMetrics(forTextStyle: style).scaledFont(for: face)
        ]
    }
}

extension View {
    /// For a screen with its own header and no nav bar. iOS 26 softens
    /// content as it scrolls under the status bar; iOS 17 doesn't, and cards
    /// and chart lines ran straight under the clock. A zero-height inset
    /// whose background reaches up into the status bar covers it there.
    @ViewBuilder func statusBarBackdrop() -> some View {
        if #available(iOS 26, *) {
            self
        } else {
            safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: 0).background(AppColor.background)
            }
        }
    }
}
