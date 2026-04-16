//
// MaterialBatchLoader.swift
// NeuraLink
//
// Created by Dedicatus on 15/04/2026.
//

@preconcurrency import Foundation

/// High-performance parallel material loader.
/// Processes multiple materials concurrently for faster loading.
public final class ParallelMaterialLoader: @unchecked Sendable {
    private let document: GLTFDocument
    private let textures: [VRMTexture]
    private let vrm0MaterialProperties: [VRM0MaterialProperty]
    private let vrmVersion: VRMSpecVersion

    public init(
        document: GLTFDocument,
        textures: [VRMTexture],
        vrm0MaterialProperties: [VRM0MaterialProperty],
        vrmVersion: VRMSpecVersion
    ) {
        self.document = document
        self.textures = textures
        self.vrm0MaterialProperties = vrm0MaterialProperties
        self.vrmVersion = vrmVersion
    }

    /// Process all materials in parallel.
    ///
    /// Material creation is CPU-bound and benefits from parallelization
    /// when there are many materials.
    /// - Parameters:
    ///   - indices: Material indices to process
    ///   - progressCallback: Called periodically with progress updates
    /// - Returns: Dictionary of processed materials
    public func loadMaterialsParallel(
        indices: [Int],
        progressCallback: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [Int: VRMMaterial] {
        let results = UncheckedMaterialDictionary()
        let totalCount = indices.count
        let progressBox = UncheckedProgressBox()

        await withTaskGroup(of: Void.self) { group in
            for materialIndex in indices {
                group.addTask { [unowned self] in
                    guard let gltfMaterial = self.document.materials?[safe: materialIndex] else {
                        return
                    }

                    let vrm0Prop =
                        materialIndex < self.vrm0MaterialProperties.count
                        ? self.vrm0MaterialProperties[materialIndex]
                        : nil

                    let material = VRMMaterial(
                        from: gltfMaterial,
                        textures: self.textures,
                        vrm0MaterialProperty: vrm0Prop,
                        vrmVersion: self.vrmVersion
                    )

                    results.set(material, for: materialIndex)

                    progressBox.increment()
                    let current = progressBox.countValue
                    await MainActor.run {
                        progressCallback?(current, totalCount)
                    }
                }
            }

            await group.waitForAll()
        }

        return results.getAll()
    }
}

// MARK: - Helper Types

/// Thread-safe dictionary for material results
private final class UncheckedMaterialDictionary: @unchecked Sendable {
    private var dict: [Int: VRMMaterial] = [:]
    private let lock = NSLock()

    func set(_ material: VRMMaterial, for index: Int) {
        lock.lock()
        dict[index] = material
        lock.unlock()
    }

    func getAll() -> [Int: VRMMaterial] {
        lock.lock()
        defer { lock.unlock() }
        return dict
    }
}

/// Thread-safe progress counter
private final class UncheckedProgressBox: @unchecked Sendable {
    private var count: Int = 0
    private let lock = NSLock()

    var countValue: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
