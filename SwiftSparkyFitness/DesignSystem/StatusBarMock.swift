//
//  StatusBarMock.swift
//  SwiftSparkyFitness
//
//  The design's status-bar component (fake clock + signal/wifi/battery
//  glyphs) is for the Figma-style device-frame mockups the design file
//  renders screens inside — a real device already draws its own live
//  status bar, so this is NOT used inside any actual app screen (stacking
//  it under the real one would show two). Kept only so a device-frame
//  preview/marketing shot can reproduce the mockup faithfully.
//

import SwiftUI

struct StatusBarMock: View {
    var body: some View {
        HStack {
            Text("9:41")
                .appBody(15, weight: .semibold)
                .foregroundStyle(AppColor.ink)
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "cellularbars")
                Image(systemName: "wifi")
                Image(systemName: "battery.100")
            }
            .font(.system(size: 13))
            .foregroundStyle(AppColor.ink)
        }
        .padding(.horizontal, 20)
        .frame(height: 54)
        .background(AppColor.background)
    }
}

#Preview {
    StatusBarMock()
}
