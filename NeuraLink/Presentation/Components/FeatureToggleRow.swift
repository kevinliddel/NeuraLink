//
//  FeatureToggleRow.swift
//  NeuraLink
//
//  Settings rows with a face: an icon tile, a title, one line of what the
//  feature does, the ⓘ for the long version, and the switch. Sub-settings
//  slot in under the row while it is on. Shared by the Autonomy screen and
//  the AI Settings cards so every screen reads the same way.
//
//  Created by Dedicatus on 20/10/2026.
//

import SwiftUI

/// Rounded icon tile in a tint, the settings-app idiom.
struct SettingsIconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            // Decorative glyph: sized to its tile, not to Dynamic Type.
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

/// A feature switch: tile, title + ⓘ, subtitle, toggle; `detail` appears
/// under it (indented to the text) while the switch is on and enabled.
struct FeatureToggleRow<Detail: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    let info: String
    @Binding var isOn: Bool
    var disabled = false
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $isOn) {
                HStack(alignment: .top, spacing: 12) {
                    SettingsIconTile(symbol: symbol, tint: tint)
                    VStack(alignment: .leading, spacing: 2) {
                        InfoToggleLabel(title: title, info: info)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .disabled(disabled)
            if isOn && !disabled {
                detail()
                    .padding(.leading, 42)
            }
        }
        .padding(.vertical, 2)
        .opacity(disabled ? 0.55 : 1)
    }
}

extension FeatureToggleRow where Detail == EmptyView {
    init(symbol: String, tint: Color, title: String, subtitle: String, info: String, isOn: Binding<Bool>, disabled: Bool = false) {
        self.init(
            symbol: symbol, tint: tint, title: title, subtitle: subtitle, info: info, isOn: isOn, disabled: disabled
        ) { EmptyView() }
    }
}

/// A labelled dropdown under a feature row.
struct SubSettingRow<Value: Hashable>: View {
    let title: String
    let items: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            DropDownSelector(items: items, selection: $selection, title: label)
                .frame(maxWidth: 160)
        }
    }
}

/// A navigation row with a tile, a title and a status line.
struct SettingsLinkRow<Destination: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                SettingsIconTile(symbol: symbol, tint: tint, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}
