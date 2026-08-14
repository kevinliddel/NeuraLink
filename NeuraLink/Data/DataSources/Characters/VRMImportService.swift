//
//  VRMImportService.swift
//  NeuraLink
//
//  Import pipeline for user-supplied VRM character models, in two phases:
//
//  stage(pickedURL:) — copies the security-scoped file into tmp staging,
//  enforces the size cap, hashes (streaming SHA-256, dedupe against
//  `imported_characters`), trial-loads the model through the real VRM engine
//  (broken files fail HERE, not at first selection), extracts the embedded
//  VRM thumbnail, and returns a candidate + validation report for the
//  confirm sheet.
//
//  finalize(_:displayName:) — after user confirmation, moves the staged files
//  into ProtectedStorage's `characters/` directory (Data Protection, excluded
//  from backup), applies the protection class, and inserts the SQL row. The
//  stored filename stem IS the persona identifier the rest of the app derives
//  from the model URL, so nothing downstream needs a mapping.
//
//  discard(_:) — cancellation cleanup. sweepStaging() — launch-time sweep of
//  candidates orphaned by a kill mid-flow (mirrors the whisper temp sweep).
//

import Foundation
import Metal
import UIKit

// MARK: - Errors

nonisolated enum VRMImportError: LocalizedError {
    case fileTooLarge(bytes: Int64, limit: Int64)
    case unreadable(detail: String)
    case notAVRM(detail: String)
    case alreadyImported(existingDisplayName: String)
    case protectedStorageUnavailable
    case insertRejected

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let bytes, let limit):
            let mb = { (v: Int64) in String(format: "%.0f MB", Double(v) / 1_048_576) }
            return "This file is \(mb(bytes)) — the limit is \(mb(limit))."
        case .unreadable(let detail):
            return "The file couldn't be read: \(detail)"
        case .notAVRM(let detail):
            return "This doesn't appear to be a valid VRM model: \(detail)"
        case .alreadyImported(let name):
            return "This model is already imported as “\(name)”."
        case .protectedStorageUnavailable:
            return "Secure storage is unavailable on this device."
        case .insertRejected:
            return "The character couldn't be saved. Please try again."
        }
    }
}

// MARK: - Validation report

/// What the confirm sheet shows before the user commits to the import.
nonisolated struct VRMValidationReport: Sendable {
    let specVersion: String
    let metaName: String?
    let authors: [String]
    let licenseURL: String?
    let avatarPermission: String?
    let commercialUsage: String?
    let fileSize: Int64
    /// Non-fatal capability gaps (missing blendshapes/bones) + size warnings.
    let warnings: [String]

    /// The VRM author restricts avatar use to themselves — the sheet shows a
    /// prominent notice the user must acknowledge.
    var isUseRestricted: Bool { avatarPermission == "onlyAuthor" }
}

/// A staged, validated import awaiting user confirmation. Files live in tmp
/// until `finalize` moves them into protected storage. Identifiable (by
/// content hash) so the confirm sheet can present it via `.sheet(item:)`.
nonisolated struct VRMImportCandidate: Sendable, Identifiable {
    var id: String { sha256 }
    let stagedModelURL: URL
    let stagedThumbnailURL: URL?
    let suggestedSlug: String
    let suggestedDisplayName: String
    let sourceFilename: String
    let sha256: String
    let fileSize: Int64
    let report: VRMValidationReport
}

// MARK: - Service

actor VRMImportService {
    static let shared = VRMImportService()

    /// Hard reject above this — `VRMModel.load` reads the whole file into RAM
    /// and textures multiply it; tune on-device if real models push the line.
    static let hardSizeLimit: Int64 = 200 * 1_048_576
    /// Allowed, but the report carries a performance warning.
    static let warnSizeThreshold: Int64 = 64 * 1_048_576

    /// Slugs that collide with bundled characters' hardcoded switches
    /// (CharacterPersona, VoiceVoxSpeaker) and must never be assigned.
    static let reservedSlugs: Set<String> = ["ekaterina", "sonya", "dedicatus"]

    private init() {}

    // MARK: - Stage

    /// Copies, validates, and hashes the picked file. Throws `VRMImportError`
    /// for anything user-actionable; the staged copy is cleaned up on failure.
    func stage(pickedURL: URL) async throws -> VRMImportCandidate {
        let staging = try Self.stagingDirectory()
        let stagedURL = staging
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("vrm")
        try Self.copySecurityScoped(from: pickedURL, to: stagedURL)

        do {
            let fileSize = RemoteAssetCache.fileSize(at: stagedURL)
            guard fileSize > 0 else {
                throw VRMImportError.unreadable(detail: "empty file")
            }
            guard fileSize <= Self.hardSizeLimit else {
                throw VRMImportError.fileTooLarge(bytes: fileSize, limit: Self.hardSizeLimit)
            }

            let sha256 = try RemoteAssetCache.sha256Hex(of: stagedURL)
            if let existing = MemoryStore.shared.importedCharacter(sha256: sha256) {
                throw VRMImportError.alreadyImported(existingDisplayName: existing.displayName)
            }

            // Trial load through the real engine — same path as displaying it,
            // so a candidate that passes here renders at selection time.
            let data = try Data(contentsOf: stagedURL)
            let model: VRMModel
            do {
                model = try await VRMModel.load(
                    from: data, filePath: stagedURL.path,
                    device: MTLCreateSystemDefaultDevice())
            } catch {
                throw VRMImportError.notAVRM(detail: "\(error)")
            }

            var warnings = Self.capabilityWarnings(for: model)
            if fileSize > Self.warnSizeThreshold {
                warnings.append(
                    "Large model (\(fileSize / 1_048_576) MB) — loading may be slow and use significant memory.")
            }

            let meta = model.meta
            let report = VRMValidationReport(
                specVersion: model.specVersion.rawValue,
                metaName: meta.name,
                authors: meta.authors,
                licenseURL: meta.licenseUrl.isEmpty ? meta.otherLicenseUrl : meta.licenseUrl,
                avatarPermission: meta.avatarPermission?.rawValue,
                commercialUsage: meta.commercialUsage?.rawValue,
                fileSize: fileSize,
                warnings: warnings)

            let stagedThumbnail = Self.extractThumbnail(from: data, into: staging)

            let sourceFilename = pickedURL.lastPathComponent
            let baseName = meta.name ?? (sourceFilename as NSString).deletingPathExtension
            nlLog("[VRMImportService] Staged candidate (spec \(report.specVersion), \(fileSize) bytes, \(warnings.count) warning(s))", level: .info)

            return VRMImportCandidate(
                stagedModelURL: stagedURL,
                stagedThumbnailURL: stagedThumbnail,
                suggestedSlug: Self.uniqueSlug(from: baseName),
                suggestedDisplayName: baseName,
                sourceFilename: sourceFilename,
                sha256: sha256,
                fileSize: fileSize,
                report: report)
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            throw error
        }
    }

    // MARK: - Finalize

    /// Moves the staged files into protected storage and registers the row.
    /// Rolls the files back out on SQL rejection so no orphan can shadow a
    /// future import.
    ///
    /// `customThumbnailPNG`: user-picked card image (raw picker bytes, any
    /// format UIImage can decode) — takes precedence over the thumbnail
    /// embedded in the VRM file; downscaled + re-encoded before hitting disk.
    func finalize(
        _ candidate: VRMImportCandidate,
        displayName: String,
        customThumbnailPNG: Data? = nil
    ) throws -> ImportedCharacter {
        guard let baseDir = try? ProtectedStorage.privateApplicationSupportURL() else {
            throw VRMImportError.protectedStorageUnavailable
        }
        let charDir = baseDir.appendingPathComponent("characters", isDirectory: true)
        try? FileManager.default.createDirectory(at: charDir, withIntermediateDirectories: true)

        // Re-unique at commit time: another import may have taken the slug
        // between stage and finalize.
        let slug = Self.uniqueSlug(from: candidate.suggestedSlug)
        let modelURL = charDir.appendingPathComponent("\(slug).vrm")

        do {
            try FileManager.default.moveItem(at: candidate.stagedModelURL, to: modelURL)
        } catch {
            throw VRMImportError.unreadable(detail: "couldn't move into secure storage: \(error.localizedDescription)")
        }
        var thumbnailURL: URL?
        let thumbnailDest = charDir.appendingPathComponent("\(slug).png")
        if let customThumbnailPNG,
           let image = UIImage(data: customThumbnailPNG),
           let png = Self.downscaledPNG(image, maxDimension: 512) {
            do {
                try png.write(to: thumbnailDest, options: .atomic)
                thumbnailURL = thumbnailDest
            } catch {
                nlLog("[VRMImportService] Custom thumbnail write failed (placeholder card instead): \(error)", level: .warning)
            }
            // The embedded thumbnail lost to the user's pick — drop the staged copy.
            if let staged = candidate.stagedThumbnailURL {
                try? FileManager.default.removeItem(at: staged)
            }
        } else if let staged = candidate.stagedThumbnailURL {
            do {
                try FileManager.default.moveItem(at: staged, to: thumbnailDest)
                thumbnailURL = thumbnailDest
            } catch {
                nlLog("[VRMImportService] Thumbnail move failed (placeholder card instead): \(error)", level: .warning)
            }
        }
        try? ProtectedStorage.protect(modelURL)
        if let thumbnailURL { try? ProtectedStorage.protect(thumbnailURL) }

        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = ImportedCharacterDraft(
            slug: slug,
            displayName: trimmedName.isEmpty ? candidate.suggestedDisplayName : trimmedName,
            filePath: "characters/\(slug).vrm",
            fileSize: candidate.fileSize,
            sha256: candidate.sha256,
            thumbnailPath: thumbnailURL.map { _ in "characters/\(slug).png" },
            sourceFilename: candidate.sourceFilename,
            vrmSpec: candidate.report.specVersion,
            metaName: candidate.report.metaName,
            metaAuthors: candidate.report.authors.isEmpty
                ? nil : candidate.report.authors.joined(separator: ", "),
            metaLicenseURL: candidate.report.licenseURL,
            metaAvatarPermission: candidate.report.avatarPermission,
            metaCommercialUsage: candidate.report.commercialUsage)

        guard let row = MemoryStore.shared.insertImportedCharacter(draft) else {
            try? FileManager.default.removeItem(at: modelURL)
            if let thumbnailURL { try? FileManager.default.removeItem(at: thumbnailURL) }
            throw VRMImportError.insertRejected
        }
        seedPersonaDefaults(slug: slug, displayName: draft.displayName)
        nlLog("[VRMImportService] Imported character '\(slug)' (\(candidate.fileSize) bytes)", level: .info)
        return row
    }

    /// Explicit persona rows for a brand-new character, so it never rides the
    /// silent generic fallbacks (and so the DropDownSelector always finds its
    /// persisted voice in the list — an absent value displays row 0 without
    /// writing back). The OpenAI prompt body is stored WITHOUT the emotion
    /// preamble; PersonaStore re-prepends it on read.
    private func seedPersonaDefaults(slug: String, displayName: String) {
        let store = MemoryStore.shared
        let openai = MemoryStore.PersonaEngine.openai
        store.setPersonaName(character: slug, engine: openai, name: displayName)
        store.setPersonaPrompt(
            character: slug, engine: openai,
            prompt: "You are \(displayName), a friendly AI companion. Keep replies brief, warm, and conversational.")
        store.setPersonaVoice(character: slug, engine: openai, voice: "alloy")
        store.setPersonaVoice(
            character: slug, engine: MemoryStore.PersonaEngine.llmJp3,
            voice: String(VoiceVoxSpeaker.defaultSpeakerID))
        store.setPersonaVoice(
            character: slug, engine: MemoryStore.PersonaEngine.local,
            voice: OpenVoiceVoicePreset.riko.rawValue)
    }

    /// Cancellation cleanup for a staged candidate.
    func discard(_ candidate: VRMImportCandidate) {
        try? FileManager.default.removeItem(at: candidate.stagedModelURL)
        if let thumb = candidate.stagedThumbnailURL {
            try? FileManager.default.removeItem(at: thumb)
        }
    }

    /// Removes staging leftovers from a previous run (app killed mid-import).
    func sweepStaging() {
        guard let dir = try? Self.stagingDirectory(),
              let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil), !items.isEmpty
        else { return }
        for item in items { try? FileManager.default.removeItem(at: item) }
        nlLog("[VRMImportService] Swept \(items.count) orphaned staging file(s)", level: .info)
    }

    // MARK: - Slug generation

    /// Lowercase `[a-z0-9_]` slug from an arbitrary display string; empty
    /// results (e.g. all-CJK names) fall back to "character".
    static func sanitizedSlug(from name: String) -> String {
        let stem = (name as NSString).deletingPathExtension.lowercased()
        var out = ""
        var pendingSeparator = false
        for scalar in stem.unicodeScalars {
            let isAlnum = (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9")
            if isAlnum {
                if pendingSeparator && !out.isEmpty { out.append("_") }
                out.unicodeScalars.append(scalar)
                pendingSeparator = false
            } else {
                pendingSeparator = true
            }
        }
        if out.count > 40 { out = String(out.prefix(40)) }
        return out.isEmpty ? "character" : out
    }

    /// Sanitizes and uniques against reserved names and existing imports.
    static func uniqueSlug(from name: String) -> String {
        let base = sanitizedSlug(from: name)
        var candidate = base
        var suffix = 2
        while reservedSlugs.contains(candidate)
            || MemoryStore.shared.importedCharacter(slug: candidate) != nil {
            candidate = "\(base)_\(suffix)"
            suffix += 1
        }
        return candidate
    }

    // MARK: - Capability warnings

    /// Non-fatal gaps: the engine degrades gracefully on all of these, but the
    /// user should know what they're getting before committing.
    private static func capabilityWarnings(for model: VRMModel) -> [String] {
        var warnings: [String] = []

        if let humanoid = model.humanoid {
            if humanoid.getBoneNode(.leftEye) == nil || humanoid.getBoneNode(.rightEye) == nil {
                warnings.append("No eye bones — the character won't make eye contact.")
            }
        } else {
            warnings.append("No humanoid rig — animations and gestures will be disabled.")
        }

        let presets = Set((model.expressions?.preset ?? [:]).keys)
        let vowels: Set<VRMExpressionPreset> = [.aa, .ih, .ou, .ee, .oh]
        let moods: Set<VRMExpressionPreset> = [.happy, .angry, .sad, .relaxed, .surprised, .neutral]

        let missingVowels = vowels.subtracting(presets)
        if missingVowels.count == vowels.count {
            warnings.append("No mouth blendshapes — lip-sync will be disabled.")
        } else if !missingVowels.isEmpty {
            warnings.append("Missing some mouth blendshapes — lip-sync will look limited.")
        }
        if !presets.contains(.blink) {
            warnings.append("No blink blendshape — the character won't blink.")
        }
        let missingMoods = moods.subtracting(presets)
        if !missingMoods.isEmpty {
            warnings.append("Missing \(missingMoods.count) of \(moods.count) emotion blendshapes — expressions will be limited.")
        }
        return warnings
    }

    // MARK: - Thumbnail extraction

    /// Pulls the VRM meta thumbnail out of the GLB binary chunk and writes a
    /// ≤512 px PNG into `directory`. VRM 1.0 pins an image index
    /// (`meta.thumbnailImage`); VRM 0.x pins a texture index (`meta.texture`).
    /// Best-effort: any failure just means a placeholder card in the picker.
    private static func extractThumbnail(from data: Data, into directory: URL) -> URL? {
        guard let (document, binary) = try? GLTFParser().parse(data: data),
              let binary else { return nil }

        var imageIndex: Int?
        if let vrm1 = document.extensions?["VRMC_vrm"] as? [String: Any],
           let meta = vrm1["meta"] as? [String: Any] {
            imageIndex = meta["thumbnailImage"] as? Int
        } else if let vrm0 = document.extensions?["VRM"] as? [String: Any],
                  let meta = vrm0["meta"] as? [String: Any],
                  let textureIndex = meta["texture"] as? Int,
                  let textures = document.textures,
                  textures.indices.contains(textureIndex) {
            imageIndex = textures[textureIndex].source
        }

        guard let imageIndex,
              let images = document.images, images.indices.contains(imageIndex),
              let viewIndex = images[imageIndex].bufferView,
              let views = document.bufferViews, views.indices.contains(viewIndex)
        else { return nil }

        let view = views[viewIndex]
        let bytes = Data(binary.dropFirst(view.byteOffset ?? 0).prefix(view.byteLength))
        guard bytes.count == view.byteLength, let image = UIImage(data: bytes) else { return nil }

        guard let png = downscaledPNG(image, maxDimension: 512) else { return nil }
        let url = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        do {
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Internal (not private): ImportedCharacterStore.setThumbnail reuses it
    /// when the user changes the card image after import.
    static func downscaledPNG(_ image: UIImage, maxDimension: CGFloat) -> Data? {
        let largest = max(image.size.width, image.size.height)
        guard largest > 0 else { return nil }
        let scale = min(1, maxDimension / largest)
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.pngData()
    }

    // MARK: - File plumbing

    private static func stagingDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vrm_import", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copies a `.fileImporter` URL into our container. The coordinated
    /// `.forUploading` read materializes iCloud Drive items that aren't
    /// downloaded locally yet.
    private static func copySecurityScoped(from source: URL, to dest: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(
            readingItemAt: source, options: [.forUploading], error: &coordinatorError
        ) { url in
            do {
                try FileManager.default.copyItem(at: url, to: dest)
            } catch {
                copyError = error
            }
        }
        if let coordinatorError {
            throw VRMImportError.unreadable(detail: coordinatorError.localizedDescription)
        }
        if let copyError {
            throw VRMImportError.unreadable(detail: copyError.localizedDescription)
        }
    }
}
