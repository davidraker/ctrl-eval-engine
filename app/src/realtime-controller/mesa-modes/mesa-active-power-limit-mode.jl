using Dates
using CtrlEvalEngine.EnergyStorageSimulators
using CtrlEvalEngine.EnergyStorageUseCases: UseCase
using CtrlEvalEngine.EnergyStorageScheduling: create_schedule_period

# using .MesaEss


struct ActivePowerLimitMode <: MesaMode
    params::MesaModeParams
    maximumChargePercentage::Float64
    maximumDischargePercentage::Float64
end


function modecontrol(
    mode::ActivePowerLimitMode,
    ess::EnergyStorageSystem,
    controller::MesaController,
    _,
    _,
    t::Dates.DateTime,
    _,
    currentIterationPower::Float64
)
maxAllowedChargePower = mode.maximumChargePercentage / 100 * p_min(ess)
maxAllowedDischargePower = mode.maximumDischargePercentage / 100 * p_max(ess)
constrainedPower = max(min(currentIterationPower, maxAllowedDischargePower), maxAllowedChargePower)
return constrainedPower - currentIterationPower
end
