//
// NeuraLinkLogger.swift
// NeuraLink
//
// Project-wide structured logging routed through `os.Logger`. Xcode 15+
// renders different levels in distinct colors in the Debug area, and
// Console.app supports full filter chains over subsystem / category /
// level. Each level also carries a leading emoji so the level is scannable
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
// Console.app users can filter by `subsystem == "com.dedicatus.NeuraLink"`
// and then narrow on `category` (one entry per source file).
//
// API:
//   nlLog("message")                                // .debug default
//   nlLog("message", level: .info)
//   nlLog("message", level: .error)
//   nlLogAnimation("frame ticked")                  // compile-gated
//   nlLogPhysics("collision")                       // compile-gated
//   nlLogLoader("loaded model")                     // compile-gated
//
// Created by Dedicatus on 14/04/2026. Generalised on 19/05/2026 (renamed
// from VRMLogger; relocated from Core/Engine/VRM/Core/ to Core/Utils/).
//

import Foundation
import os

// MARK: - Build configuration validation

#if DEBUG && !VRM_METALKIT_ENABLE_LOGS && !VRM_METALKIT_ENABLE_DEBUG_ANIMATION && !VRM_METALKIT_ENABLE_DEBUG_PHYSICS && !VRM_METALKIT_ENABLE_DEBUG_LOADER
    private let __nlLoggerDebugNotice: Void = {
        fputs(
            "⚠️ NeuraLink: Debug build without VRM logging flags. Define VRM_METALKIT_ENABLE_LOGS to re-enable VRM-specific debug output.\n",
            stderr)
    }()
#endif

#if !DEBUG && (VRM_METALKIT_ENABLE_LOGS || VRM_METALKIT_ENABLE_DEBUG_ANIMATION || VRM_METALKIT_ENABLE_DEBUG_PHYSICS || VRM_METALKIT_ENABLE_DEBUG_LOADER)
    private let __nlLoggerReleaseNotice: Void = {
        fputs(
            "⚠️ NeuraLink: Release build with debug logging enabled. Disable VRM_METALKIT_ENABLE_* flags for best performance.\n",
            stderr)
    }()
#endif

// MARK: - Levels

enum NLLogLevel: String {
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

    /// Maps the seven app-level levels onto OSLog's five physical streams.
    /// Emoji disambiguates within streams (warning/error both go to
    /// `.error`; trace/debug both to `.debug`).
    fileprivate var osLogType: OSLogType {
        switch self {
        case .trace, .debug:    return .debug
        case .info:             return .info
        case .notice:           return .default
        case .warning, .error:  return .error
        case .critical:         return .fault
        }
    }
}

// MARK: - Logger cache

private enum LoggerHub {
    /// Subsystem shown in Console.app filtering. Anchored to the bundle
    /// identifier so the entry doesn't proliferate as we add categories.
    static let subsystem = "com.dedicatus.NeuraLink"

    private struct Pair {
        let logger: Logger
        let osLog: OSLog
    }

    private static var cache: [String: Pair] = [:]
    private static let lock = NSLock()

    /// Returns a cached `Logger` + raw `OSLog` for `category`. The raw
    /// `OSLog` is used for the `isEnabled(type:)` gate before we evaluate
    /// the message autoclosure — without that check, Logger's string
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
    // identifier like "LocalLLMManager+Engine".
    let raw = String(describing: fileID)
    let afterSlash = raw.split(separator: "/").last.map(String.init) ?? raw
    return afterSlash.replacingOccurrences(of: ".swift", with: "")
}

/// Dispatches `body` to the level-specific Logger method so each level
/// flows through the right stream (debug/info/default/error/fault). The
/// reason this isn't `logger.log(level:_:)` is that Logger's level-specific
/// methods are what Xcode's Debug area uses for color.
@inline(__always)
private func emit(
    _ body: String,
    level: NLLogLevel,
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

/// Sensitive-payload variant of `emit`: marks the body with
/// `privacy: .private` so the OS auto-redacts the interpolated string
/// when the logs are read from a non-developer Console (TestFlight tester
/// hooking up Console.app, MDM log capture, etc.). The category tail
/// stays `.public` because file/function/line is metadata, not content.
///
/// When viewing from Xcode's debugger or a profile-paired Console with the
/// "Enable Private Data" entitlement, the body still appears in full —
/// developers can debug; observers can't snoop.
@inline(__always)
private func emitSensitive(
    _ body: String,
    level: NLLogLevel,
    logger: Logger,
    function: String,
    line: UInt
) {
    let tail = "[\(function)#\(line)]"
    switch level {
    case .trace, .debug:
        logger.debug("\(level.emoji) \(body, privacy: .private) \(tail, privacy: .public)")
    case .info:
        logger.info("\(level.emoji) \(body, privacy: .private) \(tail, privacy: .public)")
    case .notice:
        logger.notice("\(level.emoji) \(body, privacy: .private) \(tail, privacy: .public)")
    case .warning, .error:
        logger.error("\(level.emoji) \(body, privacy: .private) \(tail, privacy: .public)")
    case .critical:
        logger.fault("\(level.emoji) \(body, privacy: .private) \(tail, privacy: .public)")
    }
}

// MARK: - Public API

@inline(__always)
func nlLog(
    _ message: @autoclosure () -> String,
    level: NLLogLevel = .debug,
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

/// Sensitive-payload variant of `nlLog`. Use for content that should not
/// land in cleartext in observer-readable system logs — chat transcripts,
/// persona system prompts, RAG memory bodies, user names, etc. The body
/// is marked `privacy: .private` so it shows as `<private>` in Console.app
/// for non-developers, and the entire call remains a no-op in Release per
/// the same DEBUG gate as `nlLog`.
///
/// API surface is intentionally identical to `nlLog` so call sites can
/// switch with a single-token rename.
@inline(__always)
func nlLogSensitive(
    _ message: @autoclosure () -> String,
    level: NLLogLevel = .debug,
    category: StaticString = #fileID,
    function: StaticString = #function,
    line: UInt = #line
) {
    #if DEBUG
        let (logger, osLog) = LoggerHub.get(deriveCategory(from: category))
        guard osLog.isEnabled(type: level.osLogType) else { return }
        emitSensitive(message(), level: level, logger: logger,
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
func nlLogAnimation(
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
func nlLogPhysics(
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
func nlLogLoader(
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
