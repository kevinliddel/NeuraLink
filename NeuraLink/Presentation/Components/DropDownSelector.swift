//
//  DropDownSelector.swift
//  NeuraLink
//
//  Created by Dedicatus on 10/07/2026.
//

import DropDown
import SwiftUI
import UIKit

/// SwiftUI wrapper around AssistoLab's UIKit `DropDown` (vendored as the
/// `DropDown/` git submodule). Renders as a full-width field — selected
/// value on the left, chevron pinned to the trailing edge — and presents
/// the DropDown panel spanning the same width, matching the upstream
/// repo's presentation. Give rows that need context a label stacked above
/// (`VStack { Text(label); DropDownSelector(...) }`) rather than beside.
struct DropDownSelector: UIViewRepresentable {
    let options: [String]
    @Binding var selectedIndex: Int

    init(options: [String], selectedIndex: Binding<Int>) {
        self.options = options
        self._selectedIndex = selectedIndex
    }

    /// Tag-style convenience mirroring `Picker(selection:)`: binds to the
    /// selected item's value rather than its position. A `selection` not
    /// present in `items` displays the first item but writes nothing back
    /// until the user actually picks.
    init<Item: Hashable>(
        items: [Item],
        selection: Binding<Item>,
        title: (Item) -> String
    ) {
        self.options = items.map(title)
        self._selectedIndex = Binding(
            get: { items.firstIndex(of: selection.wrappedValue) ?? 0 },
            set: { index in
                guard items.indices.contains(index) else { return }
                selection.wrappedValue = items[index]
            }
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = .label
        // Trailing inset reserves room for the chevron pinned below.
        config.contentInsets = NSDirectionalEdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 42)

        let button = UIButton(configuration: config)
        button.contentHorizontalAlignment = .leading

        // Bordered-field chrome so the control reads as a dropdown rather
        // than plain text. CGColor doesn't adapt to appearance changes on
        // its own, hence the trait-change re-resolution.
        button.layer.borderWidth = 1
        button.layer.borderColor = UIColor.separator.resolvedColor(with: button.traitCollection).cgColor
        button.layer.cornerRadius = 10
        button.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (button: UIButton, _) in
            button.layer.borderColor = UIColor.separator.resolvedColor(with: button.traitCollection).cgColor
        }

        let chevron = UIImageView(
            image: UIImage(systemName: "chevron.down")?
                .applyingSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        )
        chevron.tintColor = .secondaryLabel
        chevron.isUserInteractionEnabled = false
        chevron.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(chevron)
        NSLayoutConstraint.activate([
            chevron.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -16),
            chevron.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])

        button.addTarget(
            context.coordinator,
            action: #selector(Coordinator.showDropDown),
            for: .touchUpInside
        )
        context.coordinator.attach(to: button)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync(button: button)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UIButton,
        context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? uiView.intrinsicContentSize.width,
            height: uiView.intrinsicContentSize.height
        )
    }

    final class Coordinator: NSObject {
        var parent: DropDownSelector
        private let dropDown = DropDown()
        private weak var button: UIButton?

        init(_ parent: DropDownSelector) {
            self.parent = parent
            super.init()

            dropDown.selectionAction = { [weak self] index, _ in
                self?.parent.selectedIndex = index
            }

            dropDown.backgroundColor = .secondarySystemGroupedBackground
            dropDown.selectionBackgroundColor = .tertiarySystemFill
            dropDown.textColor = .label
            dropDown.selectedTextColor = .label
            dropDown.textFont = .preferredFont(forTextStyle: .body)
            dropDown.cornerRadius = 12
            dropDown.shadowColor = .black
            dropDown.shadowOpacity = 0.25
            dropDown.shadowRadius = 16
        }

        func attach(to button: UIButton) {
            self.button = button
            dropDown.anchorView = button
        }

        func sync(button: UIButton) {
            dropDown.dataSource = parent.options
            if parent.options.indices.contains(parent.selectedIndex) {
                dropDown.selectRow(at: parent.selectedIndex)
                button.configuration?.title = parent.options[parent.selectedIndex]
            } else {
                button.configuration?.title = ""
            }
        }

        @objc func showDropDown() {
            guard let button else { return }
            // No explicit width: DropDown defaults the panel to the anchor's
            // width, and the anchor now spans the full row.
            dropDown.bottomOffset = CGPoint(x: 0, y: button.bounds.height + 4)
            dropDown.show()
        }
    }
}
