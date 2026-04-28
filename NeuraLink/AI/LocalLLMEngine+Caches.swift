//
//  LocalLLMEngine+Caches.swift
//  NeuraLink
//
//  Created by Dedicatus on 28/04/2026.
//

import CoreML
import Foundation

extension LocalLLMEngine {
    // MARK: - KV Cache Management

    internal func prepareManualCaches() {
        kvCaches = []
        for chunk in bodyChunks {
            var chunkCaches: [String: MLMultiArray] = [:]
            let inputs = chunk.modelDescription.inputDescriptionsByName
            for (name, desc) in inputs {
                if name.contains("cache") || name == "old_k_cache" || name == "old_v_cache",
                    let constraint = desc.multiArrayConstraint {
                    let dataType = constraint.dataType
                    if let arr = try? MLMultiArray(shape: constraint.shape, dataType: dataType) {
                        zeroFill(arr)
                        chunkCaches[name] = arr
                    }
                }
            }
            kvCaches.append(chunkCaches)
        }
        print(
            "[LlamaEngine] Initialized manual KV caches for \(kvCaches.filter { !$0.isEmpty }.count) chunks."
        )
    }

    internal func zeroFill(_ arr: MLMultiArray) {
        if arr.dataType == .float16 {
            let ptr = arr.dataPointer.bindMemory(to: Float16.self, capacity: arr.count)
            for j in 0..<arr.count { ptr[j] = 0 }
        } else if arr.dataType == .float32 {
            let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: arr.count)
            for j in 0..<arr.count { ptr[j] = 0 }
        }
    }

    internal func slidingWindowUpdate(old: MLMultiArray?, new: MLMultiArray, expected: [NSNumber])
        -> MLMultiArray? {
        guard let old = old else { return nil }
        // For Llama 3.2 1B: Old is [1, 448, 1, 512], New is [1, 64, 1, 512]
        // We shift 'old' by 64 and append 'new' to get the next 'old' of size 448?
        // Wait, if next input is 448, and we just got 64, the next 448 should be the LAST 448 of (old + new).
        // Total tokens = 448 + 64 = 512. Last 448 = (old[64...448] + new[0...64]).

        do {
            let result = try MLMultiArray(shape: expected, dataType: old.dataType)
            let oldSize = old.count
            let newSize = new.count
            let expectedSize = result.count

            // This is a simplified flat-copy for the head-dim flattened tensors.
            // Shift old: copy from index newSize of old into 0 of result.
            let shiftAmount = newSize
            let copyFromOldCount = oldSize - shiftAmount

            if old.dataType == .float16 {
                let oldPtr = old.dataPointer.bindMemory(to: Float16.self, capacity: oldSize)
                let newPtr = new.dataPointer.bindMemory(to: Float16.self, capacity: newSize)
                let resPtr = result.dataPointer.bindMemory(to: Float16.self, capacity: expectedSize)
                for i in 0..<copyFromOldCount { resPtr[i] = oldPtr[i + shiftAmount] }
                for i in 0..<newSize { resPtr[i + copyFromOldCount] = newPtr[i] }
            } else if old.dataType == .float32 {
                let oldPtr = old.dataPointer.bindMemory(to: Float.self, capacity: oldSize)
                let newPtr = new.dataPointer.bindMemory(to: Float.self, capacity: newSize)
                let resPtr = result.dataPointer.bindMemory(to: Float.self, capacity: expectedSize)
                for i in 0..<copyFromOldCount { resPtr[i] = oldPtr[i + shiftAmount] }
                for i in 0..<newSize { resPtr[i + copyFromOldCount] = newPtr[i] }
            }
            return result
        } catch {
            return nil
        }
    }

    /// Returns the position scalar needed by chunk1 (`full_sequence_length`).
    /// The cache-processor in this model is a KV-cache updater that runs on ANE,
    /// not a position-input generator — calling it here with zeros was causing 255+
    /// synchronous CPU predictions during prefill (the inference hang).
    internal func buildPositionInputs(from pos: Int) -> [String: MLFeatureValue] {
        let posArr = try! MLMultiArray(shape: [1], dataType: .int32)
        posArr[0] = NSNumber(value: Int32(pos + 1))
        return ["full_sequence_length": MLFeatureValue(multiArray: posArr)]
    }
}
