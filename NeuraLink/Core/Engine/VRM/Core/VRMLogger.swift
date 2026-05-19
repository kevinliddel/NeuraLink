//
// VRMLogger.swift
// NeuraLink
//
// Structured logging routed through `os.Logger` so the Xcode Debug area
// (15+) and Console.app both render different log levels in distinct
// colors. Each level also carries a leading emoji so the level is scannable
// in plain-text log dumps where OSLog level color isn't applied:
//
//   trace    🔍 — gray (debug stream)
//   debug    ⚪ — gray (debug stream)
//   info     🔵 — default
//   notice   ✦  — default
//   warning  ⚠️ — yellow caution (error stream)
//   error    ❌ — yellow caution (error stream)
//   critical 🚨 — red (fault stream)
//
// Call sites are unchanged from the previous Swift.print-based version:
//
//   vrmLog("message", level: .warning)
//   vrmLogAnimation("frame ticked")
//   vrmLogPhysics("collision")
//   vrmLogLoader("loaded model")
//
// Console.app users can filter by `subsystem == "com.neuralink.app"` and
// then narrow on `category` (one entry per source file).
//
// Created by Dedicatus on 14/04/2026.
//

import Foundation
import os

// MARK: - Build configuration validation (unchanged)

#if DEBUG && !VRM_METALKIT_ENABLE_LOGS && !VRM_METALKIT_ENABLE_DEBUG_ANIMATION && !VRM_METALKIT_ENABLE_DEBUG_PHYSICS && !VRM_METALKIT_ENABLE_DEBUG_LOADER
    private let __vrmLoggerDebugNotice: Void = {
        fputs(
            "⚠️ NeuraLink: Debug build without logging. Define VRM_METALKIT_ENABLE_LOGS to re-enable debug output.\n",
            stderr)
    }()
#endif

#if !DEBUG && (VRM_METALKIT_ENABLE_LOGS || VRM_METALKIT_ENABLE_DEBUG_ANIMATION || VRM_METALKIT_ENABLE_DEBUG_PHYSICS || VRM_METALKIT_ENABLE_DEBUG_LOADER)
    private let __vrmLoggerReleaseNotice: Void = {
        fputs(
            "⚠️ NeuraLink: Release build with debug logging enabled. Disable VRM_METALKIT_ENABLE_* flags for best performance.\n",
            stderr)
    }()
#endif

// MARK: - Levels

enum VRMLogLevel: String {
    case trace = "TRACE"
    case debug = "DEBUG"
    case info = "INFO"
    case notice = "NOTICE"
    case warning = "WARNING"
    case error = "ERROR"
    case critical = "CRITICAL"

    /// Leading emoji prefix shown in the message body. Stacks with OSLog's
    /// native level coloring in Console.app / Xcode 15+ Debug area.
    fileprivate var emoji: String {
        switch self {
        case .trace:    return "🔍"
        case .debug:    return "⚪"
        case .info:     return "🔵"
        case .notice:   return "✦"
        case .warning:  return "⚠️"
        case .error:    return "❌"
        case .critical: return "🚨"
        }
    }

    /// OSLog level used to gate emission. We map seven app-level levels
    /// onto OSLog's five physical streams; the emoji disambiguates within
    /// the same OSLog level (warning/error share `.error`, trace/debug
    /// share `.debug`).
    fileprivate var osLogType: OSLogType {
        switch self {
        case .trace, .debug:  return .debug
        case .info:           return .info
        case .notice:         return .default
        case .warning, .error: return .error
        case .critical:       return .fault
        }
    }
}

// MARK: - Logger cache

private enum LoggerHub {
    /// Subsystem identifier shown in Console.app filtering. Anchored to
    /// the bundle identifier so subsystem entries don't proliferate as we
    /// add categories.
    static let subsystem = "com.dedicatus.NeuraLink"

    private struct Pair {
        let logger: Logger
        let osLog: OSLog
    }

    private static var cache: [String: Pair] = [:]
    private static let lock = NSLock()

    /// Returns a cached `Logger` + raw `OSLog` for `category`. The raw
    /// `OSLog` is used for the `isEnabled(type:)` gate before we evaluate
    /// the message autoclosure — without that check Logger's string
    /// interpolation would still call into the autoclosure even when the
    /// level is disabled at the OS, defeating the perf benefit.
    static func get(_ category: String) -> (Logger, OSLog) {
        lock.lock(); defer { lock.unlock() }
        if let pair = cache[category] {
            return (pair.logger, pair.osLog)
        }
        let logger = Logger(subsystem: subsystem, category: category)
        let osLog = OSLog(subsystem: subsystem, category: category)
        cache[category] = Pair(logger: logger, osLog: osLog)
        return (logger, osLog)
    }
}

@inline(__always)
private func deriveCategory(from fileID: StaticString) -> String {
    // `#fileID` is "ModuleName/RelativePath.swift". Strip module prefix
    // and `.swift` suffix so the category in Console.app is a clean
    // identifier like "VRMPipelineCache".
    let raw = String(describing: fileID)
    let afterSlash = raw.split(separator: "/").last.map(String.init) ?? raw
    return afterSlash.replacingOccurrences(of: ".swift", with: "")
}

/// Dispatches `body` to the level-specific Logger method so each level
/// flows through the right stream (debug/info/default/error/fault). The
/// only reason this isn't `logger.log(level:_:)` is that Logger's
/// level-specific methods are what Xcode's Debug area uses for color.
@inline(__always)
private func emit(
    _ body: String,
    level: VRMLogLevel,
    logger: Logger,
    function: String,
    line: UInt
) {
    let tail = "[\(function)#\(line)]"
    switch level {
    case .trace, .debug:
        logger.debug("\(level.emoji) \(body, privacy: .public) \(tail, privacy: .public)")
    case .info:
        logger.info("\(level.emoji) \(body, privacy: .public) \(tail, privacy: .public)")
    case .notice:
        logger.notice("\(level.emoji) \(body, privacy: .public) \(tail, privacy: .public)")
    case .warning, .error:
        logger.error("\(level.emoji) \(body, privacy: .public) \(tail, privacy: .public)")
    case .critical:
        logger.fault("\(level.emoji) \(body, privacy: .public) \(tail, privacy: .public)")
    }
}

// MARK: - Public API (signatures unchanged from the previous print-based version)

@inline(__always)
func vrmLog(
    _ message: @autoclosure () -> String,
    level: VRMLogLevel = .debug,
    category: StaticString = #fileID,
    function: StaticString = #function,
    line: UInt = #line
) {
    #if DEBUG
        let (logger, osLog) = LoggerHub.get(deriveCategory(from: category))
        guard osLog.isEnabled(type: level.osLogType) else { return }
        emit(message(), level: level, logger: logger,
              function: String(describing: function), line: line)
    #else
        _ = message
        _ = level
        _ = category
        _ = function
        _ = line
    #endif
}

/// Animation-specific debug logging (gated by VRM_METALKIT_ENABLE_DEBUG_ANIMATION).
@inline(__always)
func vrmLogAnimation(
    _ message: @autoclosure () -> String,
    category: StaticString = #fileID,
    function: StaticString = #function,
    line: UInt = #line
) {
    #if VRM_METALKIT_ENABLE_DEBUG_ANIMATION
        let (logger, osLog) = LoggerHub.get("Animation")
        guard osLog.isEnabled(type: .debug) else { return }
        let body = "🎞 \(message()) [\(deriveCategory(from: category))]"
        logger.debug("\(body, privacy: .public) [\(String(describing: function), privacy: .public)#\(line)]")
    #else
        _ = message
        _ = category
        _ = function
        _ = line
    #endif
}

/// Physics/SpringBone-specific debug logging (gated by VRM_METALKIT_ENABLE_DEBUG_PHYSICS).
@inline(__always)
func vrmLogPhysics(
    _ message: @autoclosure () -> String,
    category: StaticString = #fileID,
    function: StaticString = #function,
    line: UInt = #line
) {
    #if VRM_METALKIT_ENABLE_DEBUG_PHYSICS
        let (logger, osLog) = LoggerHub.get("Physics")
        guard osLog.isEnabled(type: .debug) else { return }
        let body = "⚙ \(message()) [\(deriveCategory(from: category))]"
        logger.debug("\(body, privacy: .public) [\(String(describing: function), privacy: .public)#\(line)]")
    #else
        _ = message
        _ = category
        _ = function
        _ = line
    #endif
}

/// Loader-specific debug logging (gated by VRM_METALKIT_ENABLE_DEBUG_LOADER).
@inline(__always)
func vrmLogLoader(
    _ message: @autoclosure () -> String,
    category: StaticString = #fileID,
    function: StaticString = #function,
    line: UInt = #line
) {
    #if VRM_METALKIT_ENABLE_DEBUG_LOADER
        let (logger, osLog) = LoggerHub.get("Loader")
        guard osLog.isEnabled(type: .debug) else { return }
        let body = "📦 \(message()) [\(deriveCategory(from: category))]"
        logger.debug("\(body, privacy: .public) [\(String(describing: function), privacy: .public)#\(line)]")
    #else
        _ = message
        _ = category
        _ = function
        _ = line
    #endif
}
