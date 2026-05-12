import Foundation

extension VRMHumanoidBone {
    /// Heuristically determines the humanoid bone type from a node name.
    /// Useful for models with missing or incomplete bone mappings.
    public static func heuristic(for name: String) -> VRMHumanoidBone? {
        let n = name.lowercased()
        let isLeft  = n.contains("_l_") || n.contains("left")
        let isRight = n.contains("_r_") || n.contains("right")
        
        if n.contains("hips") { return .hips }
        if n.contains("upperchest") || (n.contains("upper") && n.contains("chest")) { return .upperChest }
        if n.contains("chest") { return .chest }
        if n.contains("spine") { return .spine }
        if n.contains("neck") { return .neck }
        if n.contains("head") { return .head }
        
        if isLeft {
            if n.contains("upperarm") { return .leftUpperArm }
            if n.contains("lowerarm") { return .leftLowerArm }
            if n.contains("hand") && !n.contains("arm") { return .leftHand }
            if n.contains("shoulder") { return .leftShoulder }
            if n.contains("upperleg") { return .leftUpperLeg }
            if n.contains("lowerleg") { return .leftLowerLeg }
            if n.contains("foot") { return .leftFoot }
            if n.contains("toe") { return .leftToes }
            if n.contains("thumb") {
                if n.contains("distal") || n.contains("2") || n.contains("end") { return .leftThumbDistal }
                if n.contains("proximal") || n.contains("1") { return .leftThumbProximal }
                return .leftThumbMetacarpal
            }
        }
        
        if isRight {
            if n.contains("upperarm") { return .rightUpperArm }
            if n.contains("lowerarm") { return .rightLowerArm }
            if n.contains("hand") && !n.contains("arm") { return .rightHand }
            if n.contains("shoulder") { return .rightShoulder }
            if n.contains("upperleg") { return .rightUpperLeg }
            if n.contains("lowerleg") { return .rightLowerLeg }
            if n.contains("foot") { return .rightFoot }
            if n.contains("toe") { return .rightToes }
            if n.contains("thumb") {
                if n.contains("distal") || n.contains("2") || n.contains("end") { return .rightThumbDistal }
                if n.contains("proximal") || n.contains("1") { return .rightThumbProximal }
                return .rightThumbMetacarpal
            }
        }
        
        return nil
    }
}
