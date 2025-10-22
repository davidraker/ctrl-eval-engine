using CtrlEvalEngine.EnergyStorageRTControl: MesaController, VertexCurve, RampParams, previous_WIP

struct ChargeDischargeStorageMode <: MesaMode
    params::MesaModeParams
    rampOrTimeConstant::Bool
    rampParams::RampParams
    minimumReservePercent::Float64
    maximumReservePercent::Float64
    activePowerTarget::Union{Float64, Nothing}
end

function modecontrol(
    mode::ChargeDischargeStorageMode,
    ess::EnergyStorageSystem,
    controller::MesaController,
    schedulePeriod::TimeFrameRow,
    _,
    t::Dates.DateTime,
    _,
    _
)
    # Use specified target percentage if it exists, otherwise, use the current SchedulePeriod power.
    activePowerTarget = mode.activePowerTarget === nothing ? average_power(schedulePeriod) / p_max(ess) * 100 : mode.activePowerTarget
    # Constrain target by storage limits.
    targetPower = activePowerTarget >= 0 ? activePowerTarget * p_max(ess) / 100 : -activePowerTarget * p_min(ess) / 100
    # Move towards the target power as approprate to time constant or ramp rate limits:
    ramping_func = mode.rampOrTimeConstant ? apply_ramps : apply_time_constants
    lastModePower = previous_WIP(mode)
    rampLimitedPower = ramping_func(ess, mode.rampParams, lastModePower, targetPower)
    
    # Apply mode-specific energy limits.
    energyLimitedPower = apply_energy_limits(ess, rampLimitedPower, Dates.Second(controller.resolution),
            mode.minimumReservePercent, mode.maximumReservePercent)
    return energyLimitedPower
end
