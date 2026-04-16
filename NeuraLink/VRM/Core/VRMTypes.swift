//
// VRMTypes.swift
// NeuraLink
//
// Created by Dedicatus on 14/04/2026.
//

import Foundation
import simd

// MARK: - VRM 1.0 Core Types

public enum VRMSpecVersion: String {
    case v0_0 = "0.0"
    case v1_0 = "1.0"
    case v1_1 = "1.1"
}

// MARK: - Humanoid Bones

public enum VRMHumanoidBone: String, CaseIterable, Sendable {
    // Required Torso
    case hips
    case spine
    case head

    // Optional Torso
    case chest
    case upperChest
    case neck

    // Required Arms
    case leftUpperArm
    case leftLowerArm
    case leftHand
    case rightUpperArm
    case rightLowerArm
    case rightHand

    // Optional Arms
    case leftShoulder
    case rightShoulder

    // Required Legs
    case leftUpperLeg
    case leftLowerLeg
    case leftFoot
    case rightUpperLeg
    case rightLowerLeg
    case rightFoot

    // Optional Legs
    case leftToes
    case rightToes

    // Twist Bones (VRM 0.0/1.0)
    case leftUpperArmTwist
    case rightUpperArmTwist
    case leftLowerArmTwist
    case rightLowerArmTwist
    case leftUpperLegTwist
    case rightUpperLegTwist
    case leftLowerLegTwist
    case rightLowerLegTwist

    // Optional Head
    case leftEye
    case rightEye
    case jaw

    // Fingers
    case leftThumbMetacarpal
    case leftThumbProximal
    case leftThumbDistal
    case leftIndexProximal
    case leftIndexIntermediate
    case leftIndexDistal
    case leftMiddleProximal
    case leftMiddleIntermediate
    case leftMiddleDistal
    case leftRingProximal
    case leftRingIntermediate
    case leftRingDistal
    case leftLittleProximal
    case leftLittleIntermediate
    case leftLittleDistal

    case rightThumbMetacarpal
    case rightThumbProximal
    case rightThumbDistal
    case rightIndexProximal
    case rightIndexIntermediate
    case rightIndexDistal
    case rightMiddleProximal
    case rightMiddleIntermediate
    case rightMiddleDistal
    case rightRingProximal
    case rightRingIntermediate
    case rightRingDistal
    case rightLittleProximal
    case rightLittleIntermediate
    case rightLittleDistal

    public var isRequired: Bool {
        switch self {
        case .hips, .spine, .head,
            .leftUpperArm, .leftLowerArm, .leftHand,
            .rightUpperArm, .rightLowerArm, .rightHand,
            .leftUpperLeg, .leftLowerLeg, .leftFoot,
            .rightUpperLeg, .rightLowerLeg, .rightFoot:
            return true
        default:
            return false
        }
    }
}

// MARK: - LookAt Types

public enum VRMLookAtType: String {
    case bone
    case expression
}

public struct VRMLookAtRangeMap {
    public var inputMaxValue: Float
    public var outputScale: Float

    public init(inputMaxValue: Float = 90.0, outputScale: Float = 1.0) {
        self.inputMaxValue = inputMaxValue
        self.outputScale = outputScale
    }
}

// MARK: - First Person

public enum VRMFirstPersonFlag: String {
    case auto
    case both
    case firstPersonOnly
    case thirdPersonOnly
}

// MARK: - Meta Information

public struct VRMMeta {
    public var name: String?
    public var version: String?
    public var authors: [String] = []
    public var copyrightInformation: String?
    public var contactInformation: String?
    public var references: [String] = []
    public var thirdPartyLicenses: String?
    public var thumbnailImage: Int?
    public var licenseUrl: String
    public var avatarPermission: VRMAvatarPermission?
    public var commercialUsage: VRMCommercialUsage?
    public var creditNotation: VRMCreditNotation?
    public var allowRedistribution: Bool?
    public var modify: VRMModifyPermission?
    public var otherLicenseUrl: String?

    public init(licenseUrl: String) {
        self.licenseUrl = licenseUrl
    }
}

public enum VRMAvatarPermission: String {
    case onlyAuthor
    case onlySeparatelyLicensedPerson
    case everyone
}

public enum VRMCommercialUsage: String {
    case personalNonProfit
    case personalProfit
    case corporation
}

public enum VRMCreditNotation: String {
    case required
    case unnecessary
}

public enum VRMModifyPermission: String {
    case prohibited
    case allowModification
    case allowModificationRedistribution
}
