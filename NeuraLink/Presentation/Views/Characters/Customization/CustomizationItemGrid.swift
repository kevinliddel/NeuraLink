//
//  CustomizationItemGrid.swift
//  NeuraLink
//
//  The catalogue half of the customization sheet: a scrolling grid of
//  light item tiles, each showing the cut-out picture of the part it
//  applies. Picture-only by design — the rendered part identifies itself
//  better than its file name would, and the name stays as the
//  accessibility label.
//

import SwiftUI

struct CustomizationItemTile: View {
    let title: String
    let image: UIImage?
    let isSelected: Bool
    /// The "keep what this character came with" tile.
    let isOriginal: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: CustomizationTheme.tileCorner)
                    .fill(CustomizationTheme.tileFill)
                content
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: CustomizationTheme.tileCorner)
                    .stroke(isSelected ? CustomizationTheme.accent : Color.black.opacity(0.06),
                            lineWidth: isSelected ? 3 : 1))
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.white, CustomizationTheme.accent)
                        .padding(4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: CustomizationTheme.tileCorner))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .padding(4)
        } else if isOriginal {
            VStack(spacing: 3) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 22, weight: .light))
                Text("Original")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(.black.opacity(0.45))
        } else {
            ProgressView().tint(.black.opacity(0.3))
        }
    }
}

/// Fixed-height, scrolling tile grid. Height holds roughly two rows so the
/// sheet keeps the avatar visible behind it.
struct CustomizationItemGrid<Item: Identifiable, Tile: View>: View {
    let items: [Item]
    let emptyHint: String?
    let isLoading: Bool
    /// Set by the sheet, which lets the user drag it shorter.
    var height: CGFloat = CustomizationTheme.gridHeight
    @ViewBuilder var tile: (Item) -> Tile
    var originalTile: () -> CustomizationItemTile

    /// A fixed column count keeps the gaps even; the tiles size themselves
    /// to the row. An adaptive grid spreads the slack into ragged gutters.
    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: CustomizationTheme.tileGap),
            count: CustomizationTheme.tileColumns)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: columns, alignment: .center, spacing: CustomizationTheme.tileGap) {
                originalTile()
                ForEach(items) { item in
                    tile(item)
                }
            }
            .padding(.vertical, 2)
            if let emptyHint, items.isEmpty, !isLoading {
                Text(emptyHint)
                    .font(.system(size: 13))
                    .foregroundColor(CustomizationTheme.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
            }
        }
        .frame(height: height)
        .overlay(alignment: .topTrailing) {
            if isLoading {
                ProgressView()
                    .tint(.white)
                    .padding(7)
                    .background(Circle().fill(Color.black.opacity(0.55)))
            }
        }
    }
}
