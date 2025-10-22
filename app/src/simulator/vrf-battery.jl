struct VRFBatterySpecs
    powerCapacityKw::Float64
    energyCapacityKwh::Float64
    roundtripEfficiency::Float64
    TsetDegreeC::Float64
    C0::Float64 # self-discharge coefficient
    C0Hot::Float64 # self-discharge coefficient adjustment when ambient temperature is higher than Tset
    C0Cold::Float64 # self-discharge coefficient adjustment when ambient temperature is lower than Tset
    C1::Float64 # Unit: 1/kWh P
    C2::Float64 # P^2 Unit: 1/kW^2/h
    C3::Float64 # 1/SOC^2 Unit: 1/h 
    C4::Float64 # P/SOC Unit: 1/kWh
    C5::Float64 # P/SOC^2 Unit: 1/kWh
    dischargeMultiplier::Float64
    chargeMultiplier::Float64
end

function VRFBatterySpecs(P, E, ηRT)
    TsetDegreeC = 9.54887218045112
    C0 = -2.52E-02
    C0Hot = 0.022958651
    C0Cold = -0.080177305
    C1 = -1.40E-01
    C2 = -1.02E+00
    C3 = -1.05E-03
    C4 = -4.84E-01
    C5 = 2.16E-02
    VRFBatterySpecs(
        P,
        E,
        ηRT,
        TsetDegreeC,
        C0,
        C0Hot,
        C0Cold,
        C1,
        C2,
        C3,
        C4,
        C5,
        5.35613e-01,
        1.34 * ηRT,
    )
end

mutable struct VRFBatteryStates
    energy::Float64 # energy state
end

struct VRFBattery <: EnergyStorageSystem
    specs::VRFBatterySpecs
    states::VRFBatteryStates
end

ηRT(specs::VRFBatterySpecs) = specs.roundtripEfficiency

ηRT(ess::VRFBattery) = ess.specs.roundtripEfficiency
# ΔSOC(
#     ess,
#     -ess.specs.powerCapacityKw / ess.specs.energyCapacityKwh,
#     1,
#     ess.specs.TsetDegreeC,
# ) /
# -ΔSOC(
#     ess,
#     ess.specs.powerCapacityKw / ess.specs.energyCapacityKwh,
#     1,
#     ess.specs.TsetDegreeC,
# )

self_discharge_rate(ess::VRFBattery) = -ess.specs.C0 / 0.9

SOC(ess::VRFBattery) = (ess.states.energy - e_min(ess)) / (e_max(ess) - e_min(ess))
energy_state(ess::VRFBattery) = ess.states.energy

e_max(ess::VRFBattery) = 0.9 * ess.specs.energyCapacityKwh
e_min(ess::VRFBattery) = 0.1 * ess.specs.energyCapacityKwh

p_max(specs::VRFBatterySpecs) = specs.powerCapacityKw
p_max(ess::VRFBattery) =
    ess.specs.powerCapacityKw *
    min(ess.states.energy / ess.specs.energyCapacityKwh * 1.98, 1)

function p_max(ess::VRFBattery, durationHour::Real, ambientTemperatureDegreeC::Real)
    s = ess.states.energy / ess.specs.energyCapacityKwh
    ΔT = ambientTemperatureDegreeC - ess.specs.TsetDegreeC
    C0_new = ess.specs.C0 * (1 + ΔT * (ΔT > 0 ? ess.specs.C0Hot : ess.specs.C0Cold))

    a = ess.specs.C2 + ess.specs.C5 / s^2
    b = ess.specs.C1 + ess.specs.C4 / s + ess.specs.C5 / s^2
    c =
        C0_new + ess.specs.C3 / s^2 -
        (0.1 - s) / durationHour / ess.specs.dischargeMultiplier

    @debug "p_max calculation" a b c
    pMaxEnergy = if b^2 - 4 * a * c ≥ 0
        ess.specs.energyCapacityKwh * (-b - sqrt(b^2 - 4 * a * c)) / 2 / a
    else
        ess.specs.powerCapacityKw
    end

    min(p_max(ess), pMaxEnergy)
end

p_min(specs::VRFBatterySpecs) = -specs.powerCapacityKw
p_min(ess::VRFBattery) =
    ess.specs.powerCapacityKw *
    max((ess.states.energy / ess.specs.energyCapacityKwh - 0.7) * 1.51 - 1, -1)

function p_min(ess::VRFBattery, durationHour::Real, ambientTemperatureDegreeC::Real)
    s = ess.states.energy / ess.specs.energyCapacityKwh
    ΔT = ambientTemperatureDegreeC - ess.specs.TsetDegreeC
    C0_new = ess.specs.C0 * (1 + ΔT * (ΔT > 0 ? ess.specs.C0Hot : ess.specs.C0Cold))

    a = ess.specs.C2 + ess.specs.C5 / s^2
    b = ess.specs.C1 + ess.specs.C4 / s + ess.specs.C5 / s^2
    c = C0_new + ess.specs.C3 / s^2 - (0.9 - s) / durationHour / ess.specs.chargeMultiplier
    @debug "p_min calculation" a b c

    pMinEnergy = if b^2 - 4 * a * c ≥ 0
        ess.specs.energyCapacityKwh * (-b - sqrt(b^2 - 4 * a * c)) / 2 / a
    else
        -ess.specs.powerCapacityKw
    end

    max(p_min(ess), pMinEnergy)
end

"""
    ΔSOC(ess::VRFBattery, p, durationHour::Real, temperatureDegreeC::Real)

Calculate the change of internal SOC of `ess` given `p`, where
`p` is the normalized discharging (positive) or charging (negative) power.

Note: `p` should be normalized by the energy capacity.
"""
function _ΔSOC(ess::VRFBattery, p, durationHour::Real, ambientTemperatureDegreeC::Real)
    s = ess.states.energy / ess.specs.energyCapacityKwh
    ΔT = ambientTemperatureDegreeC - ess.specs.TsetDegreeC
    durationHour *
    (
        ess.specs.C0 * (1 + ΔT * (ΔT > 0 ? ess.specs.C0Hot : ess.specs.C0Cold)) +
        ess.specs.C1 * p +
        ess.specs.C2 * p^2 +
        ess.specs.C3 / s^2 +
        ess.specs.C4 * p / s +
        ess.specs.C5 * p / s^2
    ) *
    (p > 0 ? ess.specs.dischargeMultiplier : ess.specs.chargeMultiplier)
end

"""
    _operate!(ess, powerKw, durationHour)

Operate `ess` with `powerKw` for `durationHour` hours
"""
function _operate!(
    ess::VRFBattery,
    powerKw::Real,
    durationHour::Real,
    temperatureDegreeC::Real,
)
    pNorm = powerKw / ess.specs.energyCapacityKwh
    ess.states.energy +=
        _ΔSOC(ess, pNorm, durationHour, temperatureDegreeC) * ess.specs.energyCapacityKwh
    ess.states.energy = min(
        max(ess.states.energy, 0.1 * ess.specs.energyCapacityKwh),
        0.9 * ess.specs.energyCapacityKwh,
    )
    return (; powerKw, SOC = SOC(ess))
end