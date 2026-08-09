//
//  VirtualSpeedModel.swift
//  FitBridgeIOS
//
//  Physics-based virtual speed, the way Zwift / MyWhoosh compute it.
//
//  A trainer's own FTMS "instantaneous speed" field is derived from flywheel/belt speed with
//  the trainer's fixed internal assumptions (a generic rider, a fixed virtual wheel
//  circumference), so it reads noticeably low next to a virtual-cycling app. Those apps ignore
//  that field entirely and integrate speed forward from power against a rider-specific drag
//  model. This does the same, which is also where "road feel" comes from: mass gives the
//  simulated bike momentum, so a surge takes a few seconds to build and stopping pedalling
//  coasts down instead of dropping to zero.
//

import Foundation

struct VirtualSpeedParameters: Equatable {
    /// Rider + bike, kg.
    var totalMassKg: Double = 84.0
    /// Coefficient of rolling resistance.
    var crr: Double = 0.004
    /// Drag area, m².
    var cda: Double = 0.30
    /// Air density, kg/m³ (1.225 = ISA sea level, the value `encodeSimPayload` also assumes).
    var airDensity: Double = 1.225
    /// Headwind, m/s. Positive = into the rider. Zwift models no wind; set 0 to match it exactly.
    var headwindMps: Double = 0.0
    /// Road gradient, percent. Positive = climbing.
    var gradePercent: Double = 0.0
    /// Wheels/drivetrain rotational inertia expressed as an equivalent extra linear mass.
    /// Only affects how briskly the bike accelerates, not steady-state speed.
    var rotatingMassKg: Double = 1.0
    /// Trainer power is already measured downstream of the drivetrain, so 1.0 (no further loss)
    /// is the right default for a direct-drive trainer.
    var drivetrainEfficiency: Double = 1.0

    static let gravity = 9.80665

    /// Steady-state power needed to hold `speedMps` against these parameters — the inverse of
    /// what `VirtualSpeedModel` integrates, used for the UI's "expected resistive power" readout.
    func resistivePower(atSpeedMps v: Double) -> Double {
        guard v > 0 else { return 0 }
        let theta = atan(gradePercent / 100.0)
        let gravityForce = totalMassKg * Self.gravity * sin(theta)
        let rollingForce = crr * totalMassKg * Self.gravity * cos(theta)
        let apparentWind = v + headwindMps
        let aeroForce = 0.5 * airDensity * cda * apparentWind * abs(apparentWind)
        return (gravityForce + rollingForce + aeroForce) * v
    }
}

final class VirtualSpeedModel {

    var parameters: VirtualSpeedParameters

    private(set) var speedMps: Double = 0

    var speedKmh: Double { speedMps * 3.6 }

    /// Integration step. Small enough that the aero term stays stable at road speeds.
    private let maxSubStep: TimeInterval = 0.05
    /// P/v goes to infinity at a standstill; below this the propulsive force is capped as if the
    /// rider were at 1 m/s, which is roughly where a real standing start is torque-limited anyway.
    private let minPropulsionSpeedMps: Double = 1.0
    /// Belt-and-braces guard so a garbage power reading can't launch the simulated bike.
    private let maxAccelerationMps2: Double = 3.0
    /// A tick longer than this means the app was suspended; don't integrate the whole gap.
    private let maxTickInterval: TimeInterval = 2.0

    init(parameters: VirtualSpeedParameters = VirtualSpeedParameters()) {
        self.parameters = parameters
    }

    func reset() {
        speedMps = 0
    }

    /// Integrates `dt` seconds forward with `powerWatts` applied at the wheel.
    func advance(dt: TimeInterval, powerWatts: Double) {
        guard dt > 0 else { return }
        var remaining = min(dt, maxTickInterval)
        while remaining > 0 {
            let step = min(remaining, maxSubStep)
            integrate(step, powerWatts: powerWatts)
            remaining -= step
        }
    }

    private func integrate(_ dt: TimeInterval, powerWatts: Double) {
        let p = parameters
        let mass = max(p.totalMassKg, 1.0)
        let effectiveMass = mass + max(0, p.rotatingMassKg)
        let theta = atan(p.gradePercent / 100.0)

        let propulsiveForce = max(0, powerWatts) * p.drivetrainEfficiency
            / max(speedMps, minPropulsionSpeedMps)

        let gravityForce = mass * VirtualSpeedParameters.gravity * sin(theta)
        // Rolling resistance only opposes actual motion — at a standstill it must not push back.
        let rollingForce = speedMps > 0.05
            ? p.crr * mass * VirtualSpeedParameters.gravity * cos(theta)
            : 0
        let apparentWind = speedMps + p.headwindMps
        // `abs` keeps the sign right for a tailwind stronger than the rider's own speed.
        let aeroForce = 0.5 * p.airDensity * p.cda * apparentWind * abs(apparentWind)

        let netForce = propulsiveForce - gravityForce - rollingForce - aeroForce
        let acceleration = min(max(netForce / effectiveMass, -maxAccelerationMps2), maxAccelerationMps2)

        speedMps = max(0, speedMps + acceleration * dt)
    }
}
