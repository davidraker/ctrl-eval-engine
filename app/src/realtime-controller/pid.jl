using Dates, DiscretePIDs
using CtrlEvalEngine.EnergyStorageSimulators
using CtrlEvalEngine.EnergyStorageUseCases: UseCase, LoadFollowing
using CtrlEvalEngine.EnergyStorageScheduling: SchedulePeriod

struct PIDController <: RTController
    resolution::Dates.Period
    Kp::Float64
    Ti::Float64
    Td::Float64
    pid::DiscretePID
end

function PIDController(resolution, Kp::Float64, Ti::Float64, Td::Float64)
    pid = DiscretePID(; K = Kp, Ts = resolution / Second(1), Ti = Ti, Td = Td)
    return PIDController(resolution, Kp, Ti, Td, pid)
end

function control(
    ess::EnergyStorageSystem,
    controller::PIDController,
    schedulePeriod::SchedulePeriod,
    useCases::AbstractVector{<:UseCase},
    t::Dates.DateTime,
    spProgress::VariableIntervalTimeSeries,
)
    control_signals = []
    scheduled_bess_power = average_power(schedulePeriod)
    actual_bess_power = isempty(spProgress.value) ? 0.0 : last(spProgress.value)
    idxloadFollowing = findfirst(uc -> uc isa LoadFollowing, useCases)
    if idxloadFollowing !== nothing
        lf = useCases[idxloadFollowing]
        expected_load, _, _ = CtrlEvalEngine.get_period(lf.forecastLoadPower, t)
        actual_load, _, _ = CtrlEvalEngine.get_period(lf.realtimeLoadPower, t)
        set_point = scheduled_bess_power - expected_load
        process_variable = actual_bess_power - actual_load
        control_signal = controller.pid(set_point, process_variable)
        push!(control_signals, control_signal)
        return FixedIntervalTimeSeries(
            t,
            controller.resolution,
            [
                min(
                    max(p_min(ess, controller.resolution), control_signal),
                    p_max(ess, controller.resolution),
                ),
            ],
        )
    else
        remainingTime = end_time(schedulePeriod) - t
        idxReg = findfirst(uc -> uc isa Regulation, useCases)
        if idxReg !== nothing
            # Regulation is selected
            ucReg::Regulation = useCases[idxReg]
            regCap = regulation_capacity(schedulePeriod)
            return scheduled_bess_power +
                   extract(ucReg.AGCSignalPu, t, end_time(schedulePeriod)) * regCap
        end

        return FixedIntervalTimeSeries(
            t,
            remainingTime,
            [
                min(
                    max(p_min(ess, remainingTime), scheduled_bess_power),
                    p_max(ess, remainingTime),
                ),
            ],
        )
    end
end
