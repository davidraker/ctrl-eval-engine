struct LiIonBatterySpecs
    powerCapacityKw::Float64
    energyCapacityKwh::Float64
    TsetDegreeC::Float64
    C0::Float64 # self-discharge coefficient
    C0Hot::Float64 # self-discharge coefficient adjustment when ambient temperature is higher than Tset
    C0Cold::Float64 # self-discharge coefficient adjustment when ambient temperature is lower than Tset
    C_p::Float64 # discharging efficiency
    C_n::Float64 # charging efficiency
    H_p::Float64 # discharging efficiency degradation coef
    H_n::Float64 # charging efficiency degradation coef
    D::NTuple{3,Float64} # degradation coefficients
end

Δd(s, p, D::NTuple{3,Float64}, durationHour::Real = 1) =
    exp(D[1] * s + D[2] * p + D[3] * p^2) * durationHour

function LiIonBatterySpecs(
    P,
    E,
    ηRT,
    cycleLife,
    C0,
    D::NTuple{3,Float64},
    R;
    lifespanCutoff = 0.8,
    cyclesPerDay = 1,
    depthOfDischarge = 0.8,
    TsetDegreeC = 9.54887218045112,
    C0Hot = 0.022958651,
    C0Cold = -0.080177305,
)
    Cp = -1 - C0 * E / P
    Cn = C0 * E / P - ηRT
    tCharge = depthOfDischarge / (C0 - Cn * P / E)
    tDischarge = -depthOfDischarge / (C0 + Cp * P / E)
    tIdlePerCycle = 24 / cyclesPerDay - tCharge - tDischarge

    d_NCycles =
        cycleLife * (
            (
                Δd(0.5 + depthOfDischarge / 2, -P / E, D) -
                Δd(0.5 - depthOfDischarge / 2, -P / E, D)
            ) / (C0 - Cn * P) / D[1] +
            (
                Δd(0.5 - depthOfDischarge / 2, P / E, D) -
                Δd(0.5 + depthOfDischarge / 2, P / E, D)
            ) / (C0 + Cp * P) / D[1] +
            (
                Δd(0.5 + depthOfDischarge / 2 + C0 * tIdlePerCycle, 0, D) -
                Δd(0.5 + depthOfDischarge / 2, 0, D)
            ) / C0 / D[1]
        )

    Hp = (-1 / lifespanCutoff - C0 / P * E - Cp) / d_NCycles
    Hn = R * Hp / Cp * Cn
    LiIonBatterySpecs(P, E, TsetDegreeC, C0, C0Hot, C0Cold, Cp, Cn, Hp, Hn, D)
end

function LFP_LiIonBatterySpecs(
    P,
    E,
    ηRT,
    cycleLife;
    lifespanCutoff = 0.8,
    cyclesPerDay = 1,
    depthOfDischarge = 0.8,
    TsetDegreeC = 9.54887218045112,
)
    C0 = -2.309E-03
    D = (1.93, -0.335, 0.986)
    R = 1 / 1.1
    LiIonBatterySpecs(
        P,
        E,
        ηRT,
        cycleLife,
        C0,
        D,
        R;
        lifespanCutoff,
        cyclesPerDay,
        depthOfDischarge,
        TsetDegreeC,
    )
end

function NMC_LiIonBatterySpecs(
    P,
    E,
    ηRT,
    cycleLife;
    lifespanCutoff = 0.8,
    cyclesPerDay = 1,
    depthOfDischarge = 0.8,
    TsetDegreeC = 9.54887218045112,
)
    C0 = -4.13E-03
    D = (1.9, -2.34, 1.21)
    R = 1 / 1.32
    LiIonBatterySpecs(
        P,
        E,
        ηRT,
        cycleLife,
        C0,
        D,
        R;
        lifespanCutoff,
        cyclesPerDay,
        depthOfDischarge,
        TsetDegreeC,
    )
end

mutable struct LiIonBatteryStates
    SOC::Float64 # state of charge
    d::Float64 # degradation
end

struct LiIonBattery <: EnergyStorageSystem
    specs::LiIonBatterySpecs
    states::LiIonBatteryStates
end

ηRT(ess::LiIonBatterySpecs) = ess.C0 * ess.energyCapacityKwh / ess.powerCapacityKw - ess.C_n
ηRT(ess::LiIonBattery) = ηRT(ess.specs)

self_discharge_rate(ess::LiIonBattery) = -ess.specs.C0

SOC(ess::LiIonBattery) = ess.states.SOC
energy_state(ess::LiIonBattery) = ess.states.SOC * ess.specs.energyCapacityKwh

e_max(ess::LiIonBattery) = ess.specs.energyCapacityKwh
e_min(_::LiIonBattery) = 0

SOH(ess::LiIonBattery) = ess.specs.C_p / (ess.specs.C_p + ess.specs.H_p * ess.states.d)

p_max(specs::LiIonBatterySpecs) = specs.powerCapacityKw
p_max(ess::LiIonBattery) = p_max(ess.specs)

function p_max(ess::LiIonBattery, durationHour::Real, ambientTemperatureDegreeC::Real)
    ΔT = ambientTemperatureDegreeC - ess.specs.TsetDegreeC
    min(
        ess.specs.powerCapacityKw,
        -(
            SOC(ess) +
            ess.specs.C0 *
            (1 + ΔT * (ΔT > 0 ? ess.specs.C0Hot : ess.specs.C0Cold)) *
            durationHour
        ) * ess.specs.energyCapacityKwh /
        ((ess.specs.C_p + ess.specs.H_p * ess.states.d) * durationHour),
    )
end

p_min(specs::LiIonBatterySpecs) = -specs.powerCapacityKw
p_min(ess::LiIonBattery) = p_min(ess.specs)

function p_min(ess::LiIonBattery, durationHour::Real, ambientTemperatureDegreeC::Real)
    ΔT = ambientTemperatureDegreeC - ess.specs.TsetDegreeC
    max(
        -ess.specs.powerCapacityKw,
        (
            1 - SOC(ess) -
            ess.specs.C0 *
            (1 + ΔT * (ΔT > 0 ? ess.specs.C0Hot : ess.specs.C0Cold)) *
            durationHour
        ) * ess.specs.energyCapacityKwh /
        ((ess.specs.C_n + ess.specs.H_n * ess.states.d) * durationHour),
    )
end

"""
    ΔSOC(ess::LiIonBattery, p_p, p_n, durationHour::Real, temperatureDegreeC::Real)

Calculate the change of SOC of `ess` given `p_p` and `p_n`, where
`p_p` is non-negative (discharging) power, `p_n` is the non-positive (charging) power,
and they shouldn't be non-zero simultaneously.

Note: both `p_p` and `p_n` should be normalized by the energy capacity.
"""
function _ΔSOC(
    ess::LiIonBattery,
    p_p,
    p_n,
    durationHour::Real,
    ambientTemperatureDegreeC::Real,
)
    ΔT = ambientTemperatureDegreeC - ess.specs.TsetDegreeC
    durationHour * (
        ess.specs.C0 * (1 + ΔT * (ΔT > 0 ? ess.specs.C0Hot : ess.specs.C0Cold)) +
        p_p * (ess.specs.C_p + ess.specs.H_p * ess.states.d) +
        p_n * (ess.specs.C_n + ess.specs.H_n * ess.states.d)
    )
end

"""
    _operate!(ess, powerKw, durationHour)

Operate `ess` with `powerKw` for `durationHour` hours
"""
function _operate!(
    ess::LiIonBattery,
    powerKw::Real,
    durationHour::Real,
    temperatureDegreeC::Real,
)
    pNorm = powerKw / ess.specs.energyCapacityKwh
    ess.states.SOC +=
        _ΔSOC(ess, max(pNorm, 0), min(pNorm, 0), durationHour, temperatureDegreeC)
    ess.states.SOC = min(max(ess.states.SOC, 0), 1)
    ess.states.d += Δd(SOC(ess), pNorm, ess.specs.D, durationHour)
    return (; powerKw, SOC = SOC(ess), SOH = SOH(ess))
end

initialize_extra_operations(ess::LiIonBattery) = ([PointSeries([SOH(ess)])], [:SOH])
