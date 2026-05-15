//
// VRMExtensionParser+LookAt.swift
// NeuraLink
//
// Created by Dedicatus on 15/04/2026.
//

import Foundation
import simd

// MARK: - LookAt Parsing

extension VRMExtensionParser {
    func parseLookAtFromFirstPerson(_ dict: [String: Any]) throws -> VRMLookAt {
        let lookAt = VRMLookAt()

        if let typeName = dict["lookAtTypeName"] as? String {
            lookAt.type = VRMLookAtType(rawValue: typeName.lowercased()) ?? .bone
        }

        if let horizontalInner = dict["lookAtHorizontalInner"] as? [String: Any] {
            lookAt.rangeMapHorizontalInner = parseVRM0LookAtCurve(horizontalInner)
        }
        if let horizontalOuter = dict["lookAtHorizontalOuter"] as? [String: Any] {
            lookAt.rangeMapHorizontalOuter = parseVRM0LookAtCurve(horizontalOuter)
        }
        if let verticalDown = dict["lookAtVerticalDown"] as? [String: Any] {
            lookAt.rangeMapVerticalDown = parseVRM0LookAtCurve(verticalDown)
        }
        if let verticalUp = dict["lookAtVerticalUp"] as? [String: Any] {
            lookAt.rangeMapVerticalUp = parseVRM0LookAtCurve(verticalUp)
        }

        return lookAt
    }

    func parseVRM0LookAtCurve(_ dict: [String: Any]) -> VRMLookAtRangeMap {
        var rangeMap = VRMLookAtRangeMap()

        if let xRange = dict["xRange"] as? Double {
            rangeMap.inputMaxValue = Float(xRange)
        } else if let xRange = dict["xRange"] as? Float {
            rangeMap.inputMaxValue = xRange
        }

        if let yRange = dict["yRange"] as? Double {
            rangeMap.outputScale = Float(yRange)
        } else if let yRange = dict["yRange"] as? Float {
            rangeMap.outputScale = yRange
        }

        return rangeMap
    }

    func parseLookAt(_ dict: [String: Any]) throws -> VRMLookAt {
        let lookAt = VRMLookAt()

        if let typeStr = dict["type"] as? String,
            let type = VRMLookAtType(rawValue: typeStr) {
            lookAt.type = type
        }

        if let offset = dict["offsetFromHeadBone"] as? [Double], offset.count == 3 {
            lookAt.offsetFromHeadBone = SIMD3<Float>(
                Float(offset[0]), Float(offset[1]), Float(offset[2]))
        } else if let offset = dict["offsetFromHeadBone"] as? [Float], offset.count == 3 {
            lookAt.offsetFromHeadBone = SIMD3<Float>(offset[0], offset[1], offset[2])
        }

        if let rangeMap = dict["rangeMapHorizontalInner"] as? [String: Any] {
            lookAt.rangeMapHorizontalInner = parseRangeMap(rangeMap)
        }
        if let rangeMap = dict["rangeMapHorizontalOuter"] as? [String: Any] {
            lookAt.rangeMapHorizontalOuter = parseRangeMap(rangeMap)
        }
        if let rangeMap = dict["rangeMapVerticalDown"] as? [String: Any] {
            lookAt.rangeMapVerticalDown = parseRangeMap(rangeMap)
        }
        if let rangeMap = dict["rangeMapVerticalUp"] as? [String: Any] {
            lookAt.rangeMapVerticalUp = parseRangeMap(rangeMap)
        }

        return lookAt
    }

    func parseRangeMap(_ dict: [String: Any]) -> VRMLookAtRangeMap {
        var rangeMap = VRMLookAtRangeMap()

        if let inputMaxValue = dict["inputMaxValue"] as? Double {
            rangeMap.inputMaxValue = Float(inputMaxValue)
        } else if let inputMaxValue = dict["inputMaxValue"] as? Float {
            rangeMap.inputMaxValue = inputMaxValue
        }

        if let outputScale = dict["outputScale"] as? Double {
            rangeMap.outputScale = Float(outputScale)
        } else if let outputScale = dict["outputScale"] as? Float {
            rangeMap.outputScale = outputScale
        }

        return rangeMap
    }
}
