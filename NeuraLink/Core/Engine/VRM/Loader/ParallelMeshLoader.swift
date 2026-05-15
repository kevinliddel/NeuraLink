//
// ParallelMeshLoader.swift
// NeuraLink
//
// Created by Dedicatus on 15/04/2026.
//

@preconcurrency import Foundation
@preconcurrency import Metal

/// High-performance parallel mesh loader.
/// Loads multiple meshes concurrently using TaskGroup for significant speedup.
public final class ParallelMeshLoader: @unchecked Sendable {
    private let device: MTLDevice?
    private let document: GLTFDocument
    private let bufferLoader: BufferLoader

    public init(
        device: MTLDevice?,
        document: GLTFDocument,
        bufferLoader: BufferLoader
    ) {
        self.device = device
        self.document = document
        self.bufferLoader = bufferLoader
    }

    /// Load all meshes in parallel using TaskGroup.
    ///
    /// This is significantly faster than sequential loading for models with many meshes.
    /// - Parameters:
    ///   - indices: Mesh indices to load
    ///   - progressCallback: Called periodically with progress updates
    /// - Returns: Array of loaded meshes (nil for failed loads)
    public func loadMeshesParallel(
        indices: [Int],
        progressCallback: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [Int: VRMMesh] {
        let results = UncheckedMeshDictionary()
        let totalCount = indices.count
        let progressBox = UncheckedProgressBox()

        // Process meshes concurrently using TaskGroup
        await withTaskGroup(of: Void.self) { group in
            for meshIndex in indices {
                group.addTask { [unowned self] in
                    guard let gltfMesh = self.document.meshes?[safe: meshIndex] else { return }

                    do {
                        let mesh = try await VRMMesh.load(
                            from: gltfMesh,
                            document: self.document,
                            device: self.device,
                            bufferLoader: self.bufferLoader
                        )
                        results.set(mesh, for: meshIndex)
                    } catch {
                        vrmLog("[ParallelMeshLoader] Failed to load mesh \(meshIndex): \(error)")
                    }

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

// MARK: - Unchecked Helper Types

/// Thread-safe dictionary for mesh results
private final class UncheckedMeshDictionary: @unchecked Sendable {
    private var dict: [Int: VRMMesh] = [:]
    private let lock = NSLock()

    func set(_ mesh: VRMMesh, for index: Int) {
        lock.lock()
        dict[index] = mesh
        lock.unlock()
    }

    func getAll() -> [Int: VRMMesh] {
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
