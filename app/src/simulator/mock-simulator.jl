
struct MockES_Specs
    powerCapacityKw::Float64
    energyCapacityKwh::Float64
    efficiency::Float64
end

mutable struct MockES_States
    SOC::Float64 # state of charge
end

struct MockSimulator <: EnergyStorageSystem
    specs::MockES_Specs
    states::MockES_States
end

"""
    _operate!(ess, powerKw, durationHour, ambientTemperatureDegreeC)

Operate `ess` with `powerKw` for `durationHour` hours at the ambient air temperature of `ambientTemperatureDegreeC` degrees Celcius.
"""
function _operate!(ess::MockSimulator, powerKw::Real, durationHour::Real, _::Real)
    ess.states.SOC =
        ess.states.SOC -
        (powerKw > 0 ? powerKw / ess.specs.efficiency : powerKw * ess.specs.efficiency) *
        durationHour / ess.specs.energyCapacityKwh
    return (; powerKw, SOC = SOC(ess))
end

SOC(ess::MockSimulator) = ess.states.SOC
energy_state(ess::MockSimulator) = ess.states.SOC * ess.specs.energyCapacityKwh

p_max(ess::MockSimulator, durationHour::Real, _::Real) = min(
    ess.specs.powerCapacityKw,
    SOC(ess) * ess.specs.energyCapacityKwh / durationHour * ess.specs.efficiency,
)
p_max(ess::MockSimulator) = ess.specs.powerCapacityKw

p_min(ess::MockSimulator, durationHour::Real, _::Real) = max(
    -ess.specs.powerCapacityKw,
    (SOC(ess) - 1) * ess.specs.energyCapacityKwh / durationHour / ess.specs.efficiency,
)
p_min(ess::MockSimulator) = -ess.specs.powerCapacityKw

e_max(ess::MockSimulator) = ess.specs.energyCapacityKwh

e_min(ess::MockSimulator) = 0

ηRT(ess::MockSimulator) = ess.specs.efficiency^2
