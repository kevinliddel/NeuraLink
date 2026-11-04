//
//  VRMPartGrafter+Anchors.swift
//  NeuraLink
//
//  A rigid part bound to two bones of one chain — a shoe on the foot and
//  the toes — keeps the DONOR's foot-to-toes offset in its inverse binds.
//  On the host the toe-bound half then hangs off the host's toe joint while
//  the rest hangs off the ankle, so wherever the two joints sit differently
//  the shoe tears at the ball of the foot. Between two flat VRoid feet the
//  offsets nearly agree; a heel's toe joint sits far lower and further
//  forward than a flat foot's, and the toe box ends up yanked off the heel.
//
//  So each follower joint is re-bound to place its vertices, in the host's
//  bind pose, exactly where the anchor's binding places them: the part sits
//  rigidly on the anchor at rest and still bends when the toes move.
//
//  The shin is a follower for the same reason. A collar, an ankle strap or
//  a boot shaft is partly weighted to the lower leg, which put it at the
//  donor's knee-to-ankle distance below the HOST's knee — on a longer or
//  shorter shin, a strap floating around the calf or sunk into the shoe.
//
//  Created by Dedicatus on 26/10/2026.
//

import Foundation
import simd

extension VRMPartGrafter {

    /// follower IBM = followerBind⁻¹ · anchorBind · anchor IBM (host bind
    /// pose), for every anchor/follower pair `kind` declares.
    static func rebindToAnchors(_ skin: VRMSkin, kind: AppearancePartKind, host: VRMModel) {
        guard ProcessInfo.processInfo.environment["NL_NO_ANCHOR_REBIND"] == nil else { return }
        for (anchorBone, followerBone) in kind.anchorFollowers {
            guard let anchorIndex = host.humanoid?.getBoneNode(anchorBone), anchorIndex < host.nodes.count,
                  let followerIndex = host.humanoid?.getBoneNode(followerBone), followerIndex < host.nodes.count,
                  let anchorJoint = skin.joints.firstIndex(where: { $0 === host.nodes[anchorIndex] }),
                  anchorJoint < skin.inverseBindMatrices.count,
                  let anchorBind = host.bindMatrix(of: anchorBone),
                  let followerBind = host.bindMatrix(of: followerBone)
            else { continue }
            let rebound = followerBind.inverse * anchorBind * skin.inverseBindMatrices[anchorJoint]
            // Every slot on the follower: the result doesn't depend on the
            // slot's own bind, and a donor can list one bone more than once.
            for (joint, node) in skin.joints.enumerated()
            where node === host.nodes[followerIndex] && joint < skin.inverseBindMatrices.count {
                skin.inverseBindMatrices[joint] = rebound
            }
        }
    }
}
