//
//  CompanionPortrait.swift
//  NeuraLink
//
//  The character's face for the pages that are "theirs" — the journal and
//  the Memory hero card (docs/LIVING_COMPANION.md). Prefers the live
//  portrait the widget pipeline renders from the loaded model (current
//  look, idle pose), and falls back to the thumbnail PNG shipped next to
//  the model file, which every character has.
//
//  Created by Dedicatus on 14/10/2026.
//

import UIKit

enum CompanionPortrait {

    /// Live portrait if the widget pipeline has rendered one, else the
    /// model's bundled thumbnail; nil only for an unknown character.
    static func image(for character: String) -> UIImage? {
        let key = character.lowercased()
        guard !key.isEmpty else { return nil }
        if let url = CompanionSnapshotStore.thumbnailURL(named: "\(key)_live.png"),
           let data = try? Data(contentsOf: url),
           let live = UIImage(data: data) {
            return live
        }
        return CompanionNotificationScheduler.characterThumbnailData(for: character).flatMap(UIImage.init(data:))
    }
}
