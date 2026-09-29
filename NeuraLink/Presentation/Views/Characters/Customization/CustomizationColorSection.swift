//
//  CustomizationColorSection.swift
//  NeuraLink
//
//  Colour half of the customization sheet: a row of one-tap hue presets
//  over the exact sliders. The recolour is an HSV shift of whatever the
//  part already is (see SlotRecolor), so a preset is a hue rotation rather
//  than an absolute colour — the swatch previews the rotation applied to a
//  reference tone so it still reads as "pick a colour".
//

import SwiftUI

struct CustomizationColorSection: View {
    let title: String
    let recolor: SlotRecolor
    let isEnabled: Bool
    @Binding var isExpanded: Bool
    var onChange: (SlotRecolor) -> Void

    /// Hue rotations offered as swatches, in degrees.
    private static let presets: [Float] = [0, 25, 60, 120, 165, -150, -95, -45]

    var body: some View {
        VStack(spacing: 8) {
            disclosure
            if isExpanded {
                swatches
                sliders
            }
        }
    }

    private var disclosure: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 15))
                    .foregroundColor(isEnabled ? CustomizationTheme.accent : CustomizationTheme.secondaryLabel)
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                if !recolor.isIdentity {
                    Circle().fill(CustomizationTheme.accent).frame(width: 7, height: 7)
                }
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(CustomizationTheme.secondaryLabel)
            }
            .foregroundColor(CustomizationTheme.label)
            .frame(height: CustomizationTheme.controlHeight)
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 14).fill(CustomizationTheme.control))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }

    private var swatches: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Self.presets, id: \.self) { hue in
                    let selected = abs(recolor.hueShift - hue) < 0.5
                    Button {
                        var next = recolor
                        next.hueShift = hue
                        onChange(next)
                    } label: {
                        Circle()
                            .fill(Self.swatchColor(hueShift: hue, recolor: recolor))
                            .frame(width: 34, height: 34)
                            .overlay(Circle().stroke(selected ? CustomizationTheme.accent : Color.white.opacity(0.25),
                                                     lineWidth: selected ? 3 : 1))
                            .overlay {
                                if hue == 0 {
                                    Image(systemName: "slash.circle")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundColor(.white.opacity(0.9))
                                }
                            }
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(hue == 0 ? "Original colour" : "Hue \(Int(hue)) degrees")
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var sliders: some View {
        VStack(spacing: 2) {
            slider("Hue", value: recolor.hueShift, range: -180...180, format: "%+.0f°") { v in
                var next = recolor
                next.hueShift = v
                onChange(next)
            }
            slider("Saturation", value: recolor.saturation, range: 0...2, format: "×%.2f") { v in
                var next = recolor
                next.saturation = v
                onChange(next)
            }
            slider("Brightness", value: recolor.brightness, range: 0.5...1.5, format: "×%.2f") { v in
                var next = recolor
                next.brightness = v
                onChange(next)
            }
        }
    }

    private func slider(
        _ label: String, value: Float, range: ClosedRange<Float>, format: String,
        onEdit: @escaping (Float) -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(CustomizationTheme.secondaryLabel)
                .frame(width: 78, alignment: .leading)
            Slider(
                value: Binding(get: { Double(value) }, set: { onEdit(Float($0)) }),
                in: Double(range.lowerBound)...Double(range.upperBound))
            .tint(CustomizationTheme.accent)
            Text(String(format: format, value))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(CustomizationTheme.secondaryLabel)
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
        }
        .frame(height: 34)
    }

    /// Reference tone rotated by `hueShift`, so the swatch previews roughly
    /// what the slider would do to a mid-saturation part.
    static func swatchColor(hueShift: Float, recolor: SlotRecolor) -> Color {
        let base = 0.03  // a warm reference hue
        let hue = (Double(base) + Double(hueShift) / 360.0).truncatingRemainder(dividingBy: 1)
        return Color(
            hue: hue < 0 ? hue + 1 : hue,
            saturation: min(1, 0.62 * Double(recolor.saturation)),
            brightness: min(1, 0.90 * Double(recolor.brightness)))
    }
}
