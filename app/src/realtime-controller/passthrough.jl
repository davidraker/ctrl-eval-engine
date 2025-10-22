
struct PassThroughController <: RTController end

function control(
    _,
    controller::PassThroughController,
    schedulePeriod::TimeFrameRow,
    useCases::AbstractVector{<:UseCase},
    t,
    _,
)
    idxReg = findfirst(uc -> uc isa Regulation, useCases)
    if idxReg !== nothing
        # Regulation is selected
        ucReg::Regulation = useCases[idxReg]
        regCap = regulation_capacity(schedulePeriod)
        return FixedIntervalTimeSeries(
            t,
            end_time(schedulePeriod) - t,
            [average_power(schedulePeriod)],
        ) + extract(ucReg.AGCSignalPu, t, end_time(schedulePeriod)) * regCap
    end

    return FixedIntervalTimeSeries(
        t,
        end_time(schedulePeriod) - t,
        [average_power(schedulePeriod)],
    )
end