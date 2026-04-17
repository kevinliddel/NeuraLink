//
// VRMLoadingOptions.swift
// NeuraLink
//
// Created by Dedicatus on 14/04/2026.
//

import Foundation

// MARK: - VRMLoadingPhase

/// Represents a specific phase of the VRM loading process.
public enum VRMLoadingPhase: String, CaseIterable, Sendable {
    case parsingGLTF = "Parsing GLTF"
    case parsingVRMExtension = "Parsing VRM Extension"
    case preloadingBuffers = "Preloading Buffers"
    case loadingTextures = "Loading Textures"
    case loadingMaterials = "Loading Materials"
    case loadingMeshes = "Loading Meshes"
    case buildingHierarchy = "Building Hierarchy"
    case loadingSkins = "Loading Skins"
    case sanitizingJoints = "Sanitizing Joints"
    case initializingPhysics = "Initializing Physics"
    case complete = "Complete"

    /// The relative weight/importance of this phase in overall progress (0.0-1.0).
    public var weight: Double {
        switch self {
        case .parsingGLTF: return 0.05
        case .parsingVRMExtension: return 0.05
        case .preloadingBuffers: return 0.03
        case .loadingTextures: return 0.34
        case .loadingMaterials: return 0.10
        case .loadingMeshes: return 0.20
        case .buildingHierarchy: return 0.05
        case .loadingSkins: return 0.10
        case .sanitizingJoints: return 0.05
        case .initializingPhysics: return 0.03
        case .complete: return 0.0
        }
    }
}

// MARK: - VRMLoadingProgress

/// Represents the current loading progress with detailed information.
public struct VRMLoadingProgress: Sendable {
    /// The current phase of loading.
    public let currentPhase: VRMLoadingPhase

    /// Progress within the current phase (0.0-1.0).
    public let phaseProgress: Double

    /// Overall progress across all phases (0.0-1.0).
    public let overallProgress: Double

    /// Number of items completed in current phase (if applicable).
    public let itemsCompleted: Int

    /// Total number of items in current phase (if applicable).
    public let totalItems: Int

    /// Time elapsed since loading started.
    public let elapsedTime: TimeInterval

    /// Estimated time remaining.
    public let estimatedTimeRemaining: TimeInterval?

    /// Human-readable description of current operation.
    public let operationDescription: String

    /// Progress as a percentage (0-100).
    public var percentage: Int {
        Int((overallProgress * 100).rounded())
    }

    public init(
        currentPhase: VRMLoadingPhase,
        phaseProgress: Double,
        overallProgress: Double,
        itemsCompleted: Int = 0,
        totalItems: Int = 0,
        elapsedTime: TimeInterval = 0,
        estimatedTimeRemaining: TimeInterval? = nil,
        operationDescription: String = ""
    ) {
        self.currentPhase = currentPhase
        self.phaseProgress = phaseProgress
        self.overallProgress = overallProgress
        self.itemsCompleted = itemsCompleted
        self.totalItems = totalItems
        self.elapsedTime = elapsedTime
        self.estimatedTimeRemaining = estimatedTimeRemaining
        self.operationDescription = operationDescription
    }
}

// MARK: - VRMLoadingOptimization

/// Performance optimization options for VRM loading.
public struct VRMLoadingOptimization: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Skip verbose logging during loading for better performance.
    public static let skipVerboseLogging = VRMLoadingOptimization(rawValue: 1 << 0)

    /// Use aggressive texture compression (may reduce quality slightly).
    public static let aggressiveTextureCompression = VRMLoadingOptimization(rawValue: 1 << 1)

    /// Skip loading secondary UV channels if present.
    public static let skipSecondaryUVs = VRMLoadingOptimization(rawValue: 1 << 2)

    /// Use parallel texture decoding where available.
    public static let parallelTextureDecoding = VRMLoadingOptimization(rawValue: 1 << 3)

    /// Load textures in parallel using TaskGroup (significantly faster for models with many textures).
    public static let parallelTextureLoading = VRMLoadingOptimization(rawValue: 1 << 4)

    /// Enable lazy texture loading (load textures on first use rather than at startup).
    public static let lazyTextureLoading = VRMLoadingOptimization(rawValue: 1 << 5)

    /// Load meshes in parallel using TaskGroup (faster for models with many meshes).
    public static let parallelMeshLoading = VRMLoadingOptimization(rawValue: 1 << 6)

    /// Preload all buffers in parallel at start (eliminates I/O during mesh/texture loading).
    public static let preloadBuffers = VRMLoadingOptimization(rawValue: 1 << 7)

    /// Process materials in parallel (faster for models with many materials).
    public static let parallelMaterialLoading = VRMLoadingOptimization(rawValue: 1 << 8)

    /// Default optimizations for production use.
    public static let `default`: VRMLoadingOptimization = [
        .skipVerboseLogging, .parallelTextureDecoding
    ]

    /// Maximum performance optimizations (may reduce quality).
    public static let maximumPerformance: VRMLoadingOptimization = [
        .skipVerboseLogging,
        .aggressiveTextureCompression,
        .skipSecondaryUVs,
        .parallelTextureDecoding,
        .parallelTextureLoading,
        .parallelMeshLoading,
        .preloadBuffers,
        .parallelMaterialLoading
    ]
}

// MARK: - VRMLoadingOptions

/// Configuration options for VRM model loading with progress and cancellation support.
public struct VRMLoadingOptions: Sendable {

    /// Callback for progress updates during loading.
    public let progressCallback: (@Sendable (VRMLoadingProgress) -> Void)?

    /// Minimum interval between progress callback invocations.
    public let progressUpdateInterval: TimeInterval

    /// Whether to enable cancellation support.
    public let enableCancellation: Bool

    /// Performance optimizations to apply.
    public let optimizations: VRMLoadingOptimization

    /// Creates loading options.
    ///
    /// - Parameters:
    ///   - progressCallback: Called periodically with loading progress. Runs on MainActor.
    ///   - progressUpdateInterval: Minimum seconds between progress updates (default: 0.1).
    ///   - enableCancellation: Whether to check for Task cancellation (default: true).
    ///   - optimizations: Performance optimizations to apply (default: .default).
    public init(
        progressCallback: (@Sendable (VRMLoadingProgress) -> Void)? = nil,
        progressUpdateInterval: TimeInterval = 0.1,
        enableCancellation: Bool = true,
        optimizations: VRMLoadingOptimization = .default
    ) {
        self.progressCallback = progressCallback
        self.progressUpdateInterval = progressUpdateInterval
        self.enableCancellation = enableCancellation
        self.optimizations = optimizations
    }

    /// Default options with no progress callback.
    public static let `default` = VRMLoadingOptions()
}

// MARK: - VRMLoadingContext

/// Actor for thread-safe loading state management.
internal actor VRMLoadingContext {
    let options: VRMLoadingOptions
    let startTime: Date
    var phaseStartTime: Date
    var currentPhase: VRMLoadingPhase
    var phaseProgress: Double
    var lastProgressUpdate: Date
    var totalItemsInPhase: Int

    init(options: VRMLoadingOptions) async {
        self.options = options
        self.startTime = Date()
        self.phaseStartTime = Date()
        self.currentPhase = .parsingGLTF
        self.phaseProgress = 0.0
        self.lastProgressUpdate = Date.distantPast
        self.totalItemsInPhase = 0
    }

    /// Check if loading should be cancelled.
    func checkCancellation() throws {
        guard options.enableCancellation else { return }

        if Task.isCancelled {
            throw VRMError.loadingCancelled
        }
    }

    /// Update to a new loading phase.
    func updatePhase(_ phase: VRMLoadingPhase, progress: Double = 0.0) async {
        currentPhase = phase
        phaseProgress = progress
        phaseStartTime = Date()

        // Report progress on phase change
        await reportProgressIfNeeded(force: true)
    }

    /// Update to a new phase with item count.
    func updatePhase(_ phase: VRMLoadingPhase, totalItems: Int) async {
        currentPhase = phase
        phaseProgress = 0.0
        totalItemsInPhase = totalItems
        phaseStartTime = Date()

        await reportProgressIfNeeded(force: true)
    }

    /// Update progress within current phase.
    func updateProgress(itemsCompleted: Int, totalItems: Int) async {
        phaseProgress = totalItems > 0 ? Double(itemsCompleted) / Double(totalItems) : 0.0
        await reportProgressIfNeeded()
    }

    /// Report progress if enough time has elapsed or forced.
    private func reportProgressIfNeeded(force: Bool = false) async {
        let now = Date()
        let timeSinceLastUpdate = now.timeIntervalSince(lastProgressUpdate)

        guard force || timeSinceLastUpdate >= options.progressUpdateInterval else {
            return
        }

        lastProgressUpdate = now

        // Calculate overall progress
        let elapsedTime = now.timeIntervalSince(startTime)
        let overallProgress = calculateOverallProgress()

        // Calculate estimated time remaining
        var estimatedTimeRemaining: TimeInterval?
        if overallProgress > 0.01 {
            let totalEstimatedTime = elapsedTime / overallProgress
            estimatedTimeRemaining = totalEstimatedTime - elapsedTime
        }

        let loadingProgress = VRMLoadingProgress(
            currentPhase: currentPhase,
            phaseProgress: phaseProgress,
            overallProgress: overallProgress,
            itemsCompleted: Int(Double(totalItemsInPhase) * phaseProgress),
            totalItems: totalItemsInPhase,
            elapsedTime: elapsedTime,
            estimatedTimeRemaining: estimatedTimeRemaining,
            operationDescription: "\(currentPhase.rawValue) (\(Int(phaseProgress * 100))%)"
        )

        // Call the callback on the main actor
        if let callback = options.progressCallback {
            await MainActor.run {
                callback(loadingProgress)
            }
        }
    }

    /// Calculate overall progress based on phase weights.
    private func calculateOverallProgress() -> Double {
        var progress: Double = 0.0
        var reachedCurrentPhase = false

        for phase in VRMLoadingPhase.allCases {
            if phase == currentPhase {
                progress += phase.weight * phaseProgress
                reachedCurrentPhase = true
                break
            } else if !reachedCurrentPhase {
                progress += phase.weight
            }
        }

        return min(progress, 1.0)
    }
}
