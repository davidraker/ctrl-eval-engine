struct RuleBasedController <: RTController
    bound::Float64
end

RuleBasedController(config::AbstractDict) = RuleBasedController(max(0, config["loadBound"]))

function control(
    ess::EnergyStorageSystem,
    controller::RuleBasedController,
    schedulePeriod::TimeFrameRow,
    useCases::AbstractArray{<:UseCase},
    t::DateTime,
    _,
)
    scheduledPower = average_power(schedulePeriod)

    idxLF = findfirst(uc -> uc isa LoadFollowing, useCases)
    idxGF = findfirst(uc -> uc isa GenerationFollowing, useCases)
    if idxLF !== nothing
        ucLF::LoadFollowing = useCases[idxLF]
        forecastLoad, _, tEndForecstLoad =
            CtrlEvalEngine.get_period(ucLF.forecastLoadPower, t)
        actualLoad, _, tEndActualLoad = CtrlEvalEngine.get_period(ucLF.realtimeLoadPower, t)
        forecastLoad = forecastLoad - scheduledPower
        tCtrlPeriodEnd =
            isnothing(tEndActualLoad) || isnothing(tEndForecstLoad) ?
            end_time(schedulePeriod) : min(tEndForecstLoad, tEndActualLoad)
        theta_low = forecastLoad - controller.bound
        theta_high = forecastLoad + controller.bound
        η = sqrt(ηRT(ess))
        batt_power = if actualLoad > theta_high
            min(p_max(ess, tCtrlPeriodEnd - t), actualLoad - theta_high)
        elseif actualLoad < theta_low
            max(p_min(ess, tCtrlPeriodEnd - t), actualLoad - theta_low)
        else
            0
        end

        @debug "Rule-based RT controller exiting" batt_power
        return FixedIntervalTimeSeries(t, tCtrlPeriodEnd - t, [batt_power])
    elseif idxGF !== nothing
        ucGF::GenerationFollowing = useCases[idxGF]
        forecastPower, _, tEndForecst = CtrlEvalEngine.get_period(ucGF.forecastPower, t)
        actualPower, _, tEndActual = CtrlEvalEngine.get_period(ucGF.realtimePower, t)
        forecastNetGen = forecastPower + scheduledPower
        tCtrlPeriodEnd =
            isnothing(tEndActual) || isnothing(tEndForecst) ? end_time(schedulePeriod) :
            min(tEndForecst, tEndActual)
        theta_low = forecastNetGen - controller.bound
        theta_high = forecastNetGen + controller.bound
        η = sqrt(ηRT(ess))
        batt_power = if actualPower > theta_high
            min(p_max(ess, tCtrlPeriodEnd - t), theta_high - actualPower)
        elseif actualPower < theta_low
            max(p_min(ess, tCtrlPeriodEnd - t), theta_low - actualPower)
        else
            0
        end

        @debug "Rule-based RT controller exiting" batt_power
        return FixedIntervalTimeSeries(t, tCtrlPeriodEnd - t, [batt_power])
    else
        # Load Following isn't selected, follow schedule
        remainingTime = end_time(schedulePeriod) - t
        idxReg = findfirst(uc -> uc isa Regulation, useCases)
        if idxReg !== nothing
            # Regulation is selected
            ucReg::Regulation = useCases[idxReg]
            regCap = regulation_capacity(schedulePeriod)
            return FixedIntervalTimeSeries(t, remainingTime, [scheduledPower]) +
                   extract(ucReg.AGCSignalPu, t, end_time(schedulePeriod)) * regCap
        else
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
end