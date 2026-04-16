//
// BufferLoader+ComponentExtraction.swift
// NeuraLink
//
// Created by Dedicatus on 15/04/2026.
//
import Foundation

// MARK: - Component Extraction & Helper Functions

extension BufferLoader {

    func extractComponent<T: Numeric>(
        from data: Data, at offset: Int, componentType: Int, as type: T.Type
    ) -> T {
        // CRITICAL: Check that we have enough bytes for the entire type, not just the offset
        switch componentType {
        case 5120:  // BYTE (1 byte)
            guard offset + MemoryLayout<Int8>.size <= data.count else { return 0 as! T }
            let value = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: Int8.self)
            }
            return T(exactly: value) ?? (0 as! T)
        case 5121:  // UNSIGNED_BYTE (1 byte)
            guard offset + MemoryLayout<UInt8>.size <= data.count else { return 0 as! T }
            let value = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt8.self)
            }
            return T(exactly: value) ?? (0 as! T)
        case 5122:  // SHORT (2 bytes)
            guard offset + MemoryLayout<Int16>.size <= data.count else { return 0 as! T }
            let value = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: Int16.self)
            }
            return T(exactly: value) ?? (0 as! T)
        case 5123:  // UNSIGNED_SHORT (2 bytes)
            guard offset + MemoryLayout<UInt16>.size <= data.count else { return 0 as! T }
            let value = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
            }
            return T(exactly: value) ?? (0 as! T)
        case 5125:  // UNSIGNED_INT (4 bytes)
            guard offset + MemoryLayout<UInt32>.size <= data.count else { return 0 as! T }
            let value = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            }
            return T(exactly: value) ?? (0 as! T)
        case 5126:  // FLOAT (4 bytes)
            guard offset + MemoryLayout<Float>.size <= data.count else { return 0 as! T }
            let value = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: Float.self)
            }
            if T.self == Float.self {
                return value as! T
            }
            return T(exactly: Int(value)) ?? (0 as! T)
        default:
            return 0 as! T
        }
    }

    func extractFloatComponent(from data: Data, at offset: Int, componentType: Int) -> Float {
        // CRITICAL: Check bounds AND use safe loadUnaligned to avoid alignment crashes
        switch componentType {
        case 5120:  // BYTE (1 byte)
            guard offset + MemoryLayout<Int8>.size <= data.count else { return 0 }
            let value = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: Int8.self)
            }
            return Float(value) / 127.0  // Normalize
        case 5121:  // UNSIGNED_BYTE (1 byte)
            guard offset + MemoryLayout<UInt8>.size <= data.count else { return 0 }
            let value = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt8.self)
            }
            return Float(value) / 255.0  // Normalize
        case 5122:  // SHORT (2 bytes)
            guard offset + MemoryLayout<Int16>.size <= data.count else { return 0 }
            let value = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: Int16.self)
            }
            return Float(value) / 32767.0  // Normalize
        case 5123:  // UNSIGNED_SHORT (2 bytes)
            guard offset + MemoryLayout<UInt16>.size <= data.count else { return 0 }
            let value = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
            }
            return Float(value) / 65535.0  // Normalize
        case 5125:  // UNSIGNED_INT (4 bytes)
            guard offset + MemoryLayout<UInt32>.size <= data.count else { return 0 }
            let value = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            }
            return Float(value)
        case 5126:  // FLOAT (4 bytes)
            guard offset + MemoryLayout<Float>.size <= data.count else { return 0 }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Float.self) }
        default:
            return 0
        }
    }

    func extractUIntComponent(from data: Data, at offset: Int, componentType: Int) -> UInt32 {
        // CRITICAL: Check bounds AND use safe loadUnaligned to avoid alignment crashes
        switch componentType {
        case 5121:  // UNSIGNED_BYTE (1 byte)
            guard offset + MemoryLayout<UInt8>.size <= data.count else { return 0 }
            let value = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt8.self)
            }
            return UInt32(value)
        case 5123:  // UNSIGNED_SHORT (2 bytes)
            guard offset + MemoryLayout<UInt16>.size <= data.count else { return 0 }
            let value = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
            }
            return UInt32(value)
        case 5125:  // UNSIGNED_INT (4 bytes)
            guard offset + MemoryLayout<UInt32>.size <= data.count else { return 0 }
            return data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            }
        case 5126:  // FLOAT (4 bytes)
            guard offset + MemoryLayout<Float>.size <= data.count else { return 0 }
            let value = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: Float.self)
            }
            return UInt32(value)
        default:
            return 0
        }
    }

    // MARK: - Helper Functions

    func componentCount(for type: String) -> Int {
        switch type {
        case "SCALAR": return 1
        case "VEC2": return 2
        case "VEC3": return 3
        case "VEC4": return 4
        case "MAT2": return 4
        case "MAT3": return 9
        case "MAT4": return 16
        default: return 1
        }
    }

    func bytesPerComponent(_ componentType: Int) -> Int {
        switch componentType {
        case 5120, 5121: return 1  // BYTE, UNSIGNED_BYTE
        case 5122, 5123: return 2  // SHORT, UNSIGNED_SHORT
        case 5125, 5126: return 4  // UNSIGNED_INT, FLOAT
        default: return 4
        }
    }

    func bytesPerElement(componentType: Int, accessorType: String) -> Int {
        return bytesPerComponent(componentType) * componentCount(for: accessorType)
    }
}
