//
//  VRMPartGrafter+Orientation.swift
//  NeuraLink
//
//  Which way a donor part faces, decided by its geometry rather than by the
//  spec version in its header. Those normally agree — VRM 0.x and 1.0 face
//  opposite ways and the renderer yaws 0.x models to match — but a file can
//  be mislabelled. One library part declares VRM 1.0 while its mesh is laid
//  out the 0.x way, so the version check left its shoe backwards and 34% of
//  the host's foot escaped past the toe. The vertices cannot be mislabelled.
//

import Foundation
import simd

extension VRMPartGrafter {

    /// A 180° yaw when the donor part points the opposite way from the host
    /// along the foot axis, or nil when the geometry can't be read and the
    /// caller should fall back to the spec versions.
    ///
    /// Compares which side of the ankle each one's mass sits on: a shoe runs
    /// toe-ward, a foot runs toe-ward, and if those disagree the part is
    /// facing backwards however its header is labelled.
    static func facesAwayFromHost(
        _ kind: AppearancePartKind, donor: VRMModel, host: VRMModel
    ) -> simd_quatf?? {
        guard kind == .shoes,
            let donorReach = forwardReach(of: donor, slots: kind.slots),
            let hostReach = forwardReach(of: host, slots: [.bodySkin], belowAnkle: true)
        else { return nil }
        guard abs(donorReach) > 0.005, abs(hostReach) > 0.005 else { return nil }
        return .some(donorReach.sign == hostReach.sign ? nil : VRMModel.vrmVersionYaw)
    }

    /// Signed distance from the ankle to the mean of the geometry along Z.
    private static func forwardReach(
        of model: VRMModel, slots: Set<VRoidMaterialSlot>, belowAnkle: Bool = false
    ) -> Float? {
        guard let ankle = model.bindPosition(of: .leftFoot) ?? model.bindPosition(of: .rightFoot)
        else { return nil }
        var total: Float = 0
        var count = 0
        for mesh in model.meshes {
            for primitive in mesh.primitives {
                guard let materialIndex = primitive.materialIndex,
                    slots.contains(model.slot(ofMaterial: materialIndex))
                else { continue }
                primitive.forEachRestPosition(budget: 20_000) { position in
                    guard abs(position.x - ankle.x) < 0.12 else { return }
                    if belowAnkle, position.y >= ankle.y { return }
                    total += position.z - ankle.z
                    count += 1
                }
            }
        }
        return count > 30 ? total / Float(count) : nil
    }
}
