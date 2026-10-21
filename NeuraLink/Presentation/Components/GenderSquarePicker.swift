//
//  GenderSquarePicker.swift
//  NeuraLink
//
//  The character's gender as two separate square tiles, ♀ and ♂ (the venus
//  and mars symbols in the asset catalogue), side by side with room between
//  them. The selected tile takes its colour and an outline; the other stays
//  quiet. Used by the import sheet and the character's settings.
//
//  Created by Dedicatus on 20/10/2026.
//

import SwiftUI

struct GenderSquarePicker: View {
    @Binding var selection: CharacterGender
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let side: CGFloat = 76

    var body: some View {
        HStack(spacing: 20) {
            ForEach(CharacterGender.allCases, id: \.self) { option in
                tile(option)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private func tile(_ option: CharacterGender) -> some View {
        let selected = option == selection
        let shape = RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous)
        return Button {
            withAnimation(reduceMotion ? nil : .snappy) { selection = option }
        } label: {
            Image(option.symbolAsset)
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(selected ? option.tint : Color.secondary)
                .frame(width: Self.side, height: Self.side)
                .background(selected ? option.tint.opacity(0.16) : Color.secondary.opacity(0.08), in: shape)
                .overlay(shape.strokeBorder(selected ? option.tint : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
                .contentShape(shape)
        }
        // Each tile its own plain button: in a Form row, buttons without an
        // explicit style fire together on any tap.
        .buttonStyle(.plain)
        .accessibilityLabel(Text(option.title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private extension CharacterGender {
    var tint: Color {
        switch self {
        case .female: return AppTheme.Tint.bond
        case .male: return .blue
        }
    }
}

#Preview {
    @Previewable @State var gender = CharacterGender.male
    Form { Section("Gender") { GenderSquarePicker(selection: $gender) } }
}
