//
//  PartsLibrary.swift
//  NeuraLink
//
//  Donor parts for character customization, cut from whole VRoid models by
//  scripts/extract_parts.py into `<model>__hair.vrm`, `<model>__outfit.vrm`,
//  one file per garment, and `<model>__eyes.vrm` (a texture donor). Each is
//  a minimal VRM with just that part, so a hair donor loads in a fraction
//  of the time the whole model took.
//
//  The files themselves are not in the app — 68 parts weigh 225 MB, more
//  than everything else together — so the library is a MANIFEST
//  (`RemoteAssetRegistry.libraryPartStems`) and each item resolves to a
//  file on demand through `RemoteAssetCache`, exactly as the environment
//  GLBs do. The pictures for the cards do ship, under Custom/Thumbs, so the
//  picker looks complete whether or not a part has arrived yet.
//
//  Library parts never appear in the character picker (VRMModelRegistry
//  only knows its named characters, the Models folder reference, and
//  imports). Donor slugs are namespaced `lib:<stem>` so a saved look can
//  tell a library file from a character with the same name.
//

import Foundation

@MainActor
final class PartsLibrary {
    static let shared = PartsLibrary()

    /// What a library file contributes.
    enum Kind: String, CaseIterable {
        case hair
        case outfit
        case tops
        case bottoms
        case shoes
        /// Eye textures (never grafted as geometry).
        case eyes

        static func from(stem: String) -> Kind? {
            for kind in allCases where stem.hasSuffix("__" + kind.rawValue) { return kind }
            return nil
        }

        /// Whether a file of this kind can serve a picker category.
        func serves(_ category: CustomizationCategory) -> Bool {
            switch (self, category) {
            case (.hair, .hair), (.outfit, .outfit), (.tops, .tops), (.bottoms, .bottoms), (.shoes, .shoes):
                return true
            case (.eyes, .eyes):
                return true
            default:
                return false
            }
        }
    }

    struct Item: Hashable, Identifiable {
        /// File stem, lowercased ("school_uniform_2__outfit").
        let stem: String
        /// "School Uniform 2"
        let displayName: String
        /// Nil for a whole-model file (serves every category).
        let kind: Kind?

        /// Where the file comes from. Downloaded once, then read from disk.
        var asset: RemoteAssetRegistry { .libraryPart(stem) }

        /// The file on disk, fetching it first if this is its first use.
        /// Throws when the part has not arrived and cannot be reached.
        func resolvedURL() async throws -> URL {
            try await RemoteAssetCache.shared.url(for: asset)
        }

        /// Whether the file is already on the device. Cheap and synchronous,
        /// for deciding what to show rather than what to load.
        var isDownloaded: Bool { asset.isCachedLocally }

        var id: String { stem }
        var donorSlug: String { PartsLibrary.slugPrefix + stem }
        /// Source model the part was cut from ("school_uniform_2"), which is
        /// what its picture files are named after.
        var modelStem: String {
            stem.range(of: "__").map { String(stem[..<$0.lowerBound]) } ?? stem
        }

        func serves(_ category: CustomizationCategory) -> Bool {
            kind?.serves(category) ?? true
        }
    }

    static let slugPrefix = "lib:"

    private(set) lazy var items: [Item] = Self.manifest()

    private init() {}

    func item(slug: String) -> Item? {
        guard slug.lowercased().hasPrefix(Self.slugPrefix) else { return nil }
        let stem = String(slug.lowercased().dropFirst(Self.slugPrefix.count))
        return items.first { $0.stem == stem }
    }

    static func isLibrarySlug(_ slug: String) -> Bool {
        slug.lowercased().hasPrefix(slugPrefix)
    }

    /// How much of the library is already on the device.
    var downloadedCount: Int { items.count { $0.isDownloaded } }

    var isFullyDownloaded: Bool { downloadedCount == items.count }

    // MARK: - Discovery

    /// The library is whatever the manifest says it is. Scanning the bundle
    /// is no longer possible — and was never right, because a part that
    /// failed to copy simply vanished from the picker instead of failing.
    private static func manifest() -> [Item] {
        RemoteAssetRegistry.libraryPartStems
            .map { stem in
                Item(stem: stem, displayName: humanize(stem), kind: Kind.from(stem: stem))
            }
            .sorted { ($0.displayName, $0.stem) < ($1.displayName, $1.stem) }
    }

    /// "school_uniform_2__outfit" → "School Uniform 2".
    static func humanize(_ stem: String) -> String {
        var base = stem
        if let range = base.range(of: "__") { base = String(base[..<range.lowerBound]) }
        return base.split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { word -> String in
                let w = String(word)
                return w.prefix(1).uppercased() + w.dropFirst()
            }
            .joined(separator: " ")
    }
}
