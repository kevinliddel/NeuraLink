//
//  PartThumbnailStore.swift
//  NeuraLink
//
//  Pictures for the customization tiles, named after the part they show
//  ("school_uniform_2__outfit.png") to match the part files themselves.
//  The bundled library ships its pictures pre-rendered; anything else
//  (imported characters) is rendered once by VRMPartThumbnailRenderer from
//  a loaded donor and cached as a PNG in Application Support, generated one
//  at a time in the background while the tiles show a placeholder.
//

import Foundation
import Observation
import UIKit

@Observable
@MainActor
final class PartThumbnailStore {
    static let shared = PartThumbnailStore()

    /// In-memory cache; observed by the cards.
    private(set) var images: [String: UIImage] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var queue: [(name: String, donorSlug: String, subject: VRMPartThumbnailRenderer.Subject)] = []
    @ObservationIgnored private var isDraining = false
    @ObservationIgnored private lazy var renderer = VRMPartThumbnailRenderer()

    private init() {}

    /// Picture file name for a part: model stem + category, mirroring the
    /// part files ("casual__hair").
    nonisolated static func thumbnailName(base: String, category: CustomizationCategory) -> String {
        "\(base.lowercased())__\(category.rawValue)"
    }

    func image(named name: String) -> UIImage? {
        if let cached = images[name] { return cached }
        // Pre-rendered pictures for the bundled parts library ship in the
        // app (App/Resources/Custom/Thumbs/<name>.png).
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
            let bundled = UIImage(contentsOfFile: url.path) {
            images[name] = bundled
            return bundled
        }
        if let disk = loadFromDisk(name) {
            images[name] = disk
            return disk
        }
        return nil
    }

    /// Schedules generation when no picture exists yet.
    func ensure(named name: String, donorSlug: String, subject: VRMPartThumbnailRenderer.Subject) {
        guard image(named: name) == nil, !inFlight.contains(name) else { return }
        inFlight.insert(name)
        queue.append((name, donorSlug, subject))
        drainIfNeeded()
    }

    // MARK: - Generation

    private func drainIfNeeded() {
        guard !isDraining, !queue.isEmpty else { return }
        isDraining = true
        Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        defer { isDraining = false }
        while !queue.isEmpty {
            // Never compete with a graft the user is waiting on.
            while AppearanceApplier.shared.isGrafting {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            let job = queue.removeFirst()
            defer { inFlight.remove(job.name) }
            guard let model = await AppearanceApplier.shared.donorModel(slug: job.donorSlug) else { continue }
            guard let renderer, let image = renderer.render(model: model, subject: job.subject) else {
                nlLog("[Thumbnails] render failed for '\(job.donorSlug)'", level: .warning)
                continue
            }
            images[job.name] = image
            saveToDisk(image, name: job.name)
            await Task.yield()
        }
    }

    // MARK: - Disk cache

    private var directory: URL? {
        guard let base = try? ProtectedStorage.privateApplicationSupportURL() else { return nil }
        // Versioned: the framing and visible parts changed, so pictures
        // cached by an older build would keep showing the old subject.
        let dir = base.appendingPathComponent("appearance-thumbs-v2", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func fileURL(_ name: String) -> URL? {
        directory?.appendingPathComponent("\(name).png")
    }

    private func loadFromDisk(_ name: String) -> UIImage? {
        guard let url = fileURL(name), let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data, scale: 2)
    }

    private func saveToDisk(_ image: UIImage, name: String) {
        guard let url = fileURL(name), let data = image.pngData() else { return }
        try? data.write(to: url, options: .atomic)
    }
}
