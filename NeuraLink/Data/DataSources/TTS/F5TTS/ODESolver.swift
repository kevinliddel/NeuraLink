//
//  ODESolver.swift
//  NeuraLink
//
//  Flow-matching ODE solvers for F5-TTS sampling.
//
//  The solver integrates dx/dt = velocity(x, t) over [0, 1] in `steps`
//  uniform steps. `MLX.eval(x)` runs at the end of every step so the lazy
//  computation graph doesn't grow to ~steps × model_size and exhaust RAM —
//  this was the failure mode that the inline loop in F5TTS.generate() had
//  to work around manually.
//
//  Created by Dedicatus on 26/05/2026.
//

import Foundation
import MLX

enum ODEMethod: String, Sendable {
    /// First-order Euler. 1 velocity eval per step. Cheapest, lowest accuracy.
    case euler

    /// Second-order midpoint (RK2). 2 velocity evals per step. Roughly half
    /// the truncation error of Euler at the cost of doubling per-step compute.
    case midpoint
}

/// Numerical integrator for the F5-TTS flow-matching ODE on [0, 1].
protocol ODESolver: Sendable {

    /// Integrates dx/dt = velocity(x, t) starting from `initial`, in `steps`
    /// uniform steps from t=0 to t=1, and returns the final state.
    func integrate(
        from initial: MLXArray,
        steps: Int,
        velocity: (MLXArray, Float) -> MLXArray
    ) -> MLXArray
}

struct EulerSolver: ODESolver {
    func integrate(
        from initial: MLXArray,
        steps: Int,
        velocity: (MLXArray, Float) -> MLXArray
    ) -> MLXArray {
        var x = initial
        let dt = Float(1.0) / Float(steps)
        for i in 0..<steps {
            let t = Float(i) * dt
            let v = velocity(x, t)
            x = x + v * dt
            MLX.eval(x)
        }
        return x
    }
}

struct MidpointSolver: ODESolver {
    func integrate(
        from initial: MLXArray,
        steps: Int,
        velocity: (MLXArray, Float) -> MLXArray
    ) -> MLXArray {
        var x = initial
        let dt = Float(1.0) / Float(steps)
        let halfDt = dt / 2.0
        for i in 0..<steps {
            let t = Float(i) * dt
            let k1 = velocity(x, t)
            let midpoint = x + k1 * halfDt
            let k2 = velocity(midpoint, t + halfDt)
            x = x + k2 * dt
            MLX.eval(x)
        }
        return x
    }
}

enum ODESolverFactory {
    static func make(_ method: ODEMethod) -> ODESolver {
        switch method {
        case .euler: return EulerSolver()
        case .midpoint: return MidpointSolver()
        }
    }
}
