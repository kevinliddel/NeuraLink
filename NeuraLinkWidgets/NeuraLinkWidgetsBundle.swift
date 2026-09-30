//
//  NeuraLinkWidgetsBundle.swift
//  NeuraLinkWidgets
//
//  Widget extension entry point (docs/PRESENCE_BEYOND_APP.md).
//

import SwiftUI
import WidgetKit

@main
struct NeuraLinkWidgetsBundle: WidgetBundle {
    var body: some Widget {
        CompanionWidget()
        ComeBackWidget()
        CompanionLiveActivity()
    }
}
