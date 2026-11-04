//
//  GenderSquarePickerSnapshot.swift
//  NeuraLinkTests
//
//  Developer tool: renders the gender tiles in both states, light and dark,
//  to a PNG so the layout can be looked at. Set NL_UI_DIAG_DIR to run.
//
//  Created by Dedicatus on 20/10/2026.
//

import Foundation
import SwiftUI
import Testing
@testable import NeuraLink

@Suite("Gender tiles snapshot")
struct GenderSquarePickerSnapshot {

    @Test("Render the gender tiles when NL_UI_DIAG_DIR is set")
    @MainActor
    func render() throws {
        guard let out = ProcessInfo.processInfo.environment["NL_UI_DIAG_DIR"], !out.isEmpty else { return }
        let view = HStack(spacing: 24) {
            ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                VStack(spacing: 12) {
                    GenderSquarePicker(selection: .constant(.female))
                    GenderSquarePicker(selection: .constant(.male))
                }
                .padding(16)
                .frame(width: 320)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .environment(\.colorScheme, scheme)
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.3))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let png = try #require(renderer.uiImage?.pngData())
        let dir = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("gender_tiles.png"))
    }
}
