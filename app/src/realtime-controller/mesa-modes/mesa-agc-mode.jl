using CtrlEvalEngine.EnergyStorageRTControl: MesaController, VertexCurve, RampParams, previous_WIP
using CtrlEvalEngine.EnergyStorageScheduling: regulation_capacity

struct AGCMode <: MesaMode
    params::MesaModeParams
    rampOrTimeConstant::Bool
    rampParams::RampParams
    minimumUsableSOC::Float64
    maximumUsableSOC::Float64
end

function modecontrol(
    mode::AGCMode,
    ess::EnergyStorageSystem,
    controller::MesaController,
    schedulePeriod::TimeFrameRow,
    useCases::AbstractVector{<:UseCase},
    t::Dates.DateTime,
    spProgress::VariableIntervalTimeSeries,
    currentIterationPower::Float64
)
    idxRegulation = findfirst(uc -> uc isa Regulation, useCases)
    if idxRegulation !== nothing
        regulationUC = useCases[idxRegulation]
        # Get Current Active Power Target (in per unit, to comply with use Case -- NOTE: MESA gives a power):
        (AGCSignalPu, _, _) = get_period(regulationUC.AGCSignalPu, t)
        # Convert per unit to the actual AGC signal (in kW, not MW) based on the regulation capacity from the sceheuler.
        activePowerTarget = regulation_capacity(schedulePeriod) * AGCSignalPu
        # Move towards the target power as approprate to time constant or ramp rate limits:
        ramping_func = mode.rampOrTimeConstant ? apply_ramps : apply_time_constants
        lastModePower = previous_WIP(mode)
        rampLimitedPower = ramping_func(ess, mode.rampParams, lastModePower, activePowerTarget)
        # Apply mode-specific energy limits.
        energyLimitedPower = apply_energy_limits(ess, rampLimitedPower, controller.resolution,
                mode.minimumUsableSOC, mode.maximumUsableSOC)
        return energyLimitedPower
    else
        # Load Following isn't selected, follow schedule
        remainingTime = EnergyStorageScheduling.end_time(schedulePeriod) - t
        return FixedIntervalTimeSeries(
            t,
            remainingTime,
            [
                min(
                    max(p_min(ess, remainingTime), scheduledPower),
                    p_max(ess, remainingTime),
                ),
            ],
        )
    end
end