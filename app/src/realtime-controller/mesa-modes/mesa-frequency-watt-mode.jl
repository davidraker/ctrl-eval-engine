using CtrlEvalEngine.EnergyStorageRTControl: MesaController, VertexCurve, RampParams

mutable struct FWState
    exceededTime::Union{Dates.DateTime, Nothing}
    activeState::Union{String, Nothing}
    hysteresisValue::Union{Float64, Nothing}
end

struct FrequencyWattMode <: MesaMode
    params::MesaModeParams
    useCurves::Bool                                     # TODO: Implement
    frequencyWattCurve::Union{VertexCurve, Nothing}     # TODO: Implement
    lowHysteresisCurve::Union{VertexCurve, Nothing}     # TODO: Implement
    highHysteresisCurve::Union{VertexCurve, Nothing}    # TODO: Implement
    startDelay::Dates.Millisecond
    stopDelay::Dates.Millisecond
    rampParams::RampParams
    minimumSoc::Union{Float64, Nothing}                                 # TODO: Implement
    maximumSoc::Union{Float64, Nothing}                                 # TODO: Implement
    useHysteresis::Bool
    useSnapshotPower::Bool
    highStartingFrequency::Float64
    lowStartingFrequency::Float64
    highStoppingFrequency::Float64
    lowStoppingFrequency::Float64
    highDischargeGradient::Float64
    lowDischargeGradient::Float64
    highChargeGradient::Float64
    lowChargeGradient::Float64
    highReturnGradient::Union{Float64, Nothing}                         # TODO: Implement
    lowReturnGradient::Union{Float64, Nothing}                          # TODO: Implement
    fwState::FWState
end

function FrequencyWattMode(
    params::MesaModeParams,
    startDelay::Dates.Millisecond,
    stopDelay::Dates.Millisecond,
    rampParams::RampParams,
    useHysteresis::Bool,
    useSnapshotPower::Bool,
    highStartingFrequency::Float64,
    lowStartingFrequency::Float64,
    highStoppingFrequency::Float64,
    lowStoppingFrequency::Float64,
    highDischargeGradient::Float64,
    lowDischargeGradient::Float64,
    highChargeGradient::Float64,
    lowChargeGradient::Float64
)
return FrequencyWattMode(params, false, nothing, nothing, nothing, startDelay, stopDelay, rampParams,
                         nothing, nothing, useHysteresis, useSnapshotPower,
                         highStartingFrequency, lowStartingFrequency, highStoppingFrequency, lowStoppingFrequency,
                         highDischargeGradient, lowDischargeGradient, highChargeGradient, lowChargeGradient,
                         nothing, nothing, FWState(nothing, nothing, nothing))
end

function modecontrol(
    mode::FrequencyWattMode,
    ess::EnergyStorageSystem,
    controller::MesaController,
    schedulePeriod::TimeFrameRow,
    useCases::AbstractVector{<:UseCase},
    t::Dates.DateTime,
    spProgress::VariableIntervalTimeSeries,
    currentIterationPower::Float64
)
    idxFrequencyResponse = findfirst(uc -> uc isa FrequencyResponse, useCases)
    if idxFrequencyResponse === nothing
        error("Disallowed set of UseCases: Only FrequencyResponse UseCase may be used with the MESA FrequencyWattMode.")
    else
        useCase = useCases[idxFrequencyResponse]
    end
    (meteredFrequency, _, _) = get_period(useCase.meteredFrequency, t)
    if mode.fwState.activeState == "HF"
        high_frequency_control(ess, mode, meteredFrequency, useCase.nominalFrequency, t, currentIterationPower)
    elseif mode.fwState.activeState == "LF"
        low_frequency_control(ess, mode, meteredFrequency, useCase.nominalFrequency, t, currentIterationPower)
    else
        inactive_control(ess, mode, meteredFrequency, useCase.nominalFrequency, t, currentIterationPower)
    end
end

function inactive_control(
    ess::EnergyStorageSystem,
    mode::FrequencyWattMode,
    meteredFrequency::Float64,
    nominalFrequency::Float64,
    t::Dates.DateTime,
    currentIterationPower::Float64
    )
    if meteredFrequency > mode.highStartingFrequency
        if mode.fwState.exceededTime === nothing
            mode.fwState.exceededTime = t
        elseif (t - mode.fwState.exceededTime) >= mode.startDelay
            clear_mode_state(mode, "HF")
            high_frequency_control(ess, mode, meteredFrequency, nominalFrequency, t, currentIterationPower)
        end
    elseif meteredFrequency <= mode.lowStartingFrequency
        if mode.fwState.exceededTime === nothing
            mode.fwState.exceededTime = t
        elseif (t - mode.fwState.exceededTime) >= mode.startDelay
            clear_mode_state(mode, "LF")
            low_frequency_control(ess, mode, meteredFrequency, nominalFrequency, t, currentIterationPower)
        end
    else
        mode.fwState.exceededTime = nothing
    end
    return 0.0
end

function high_frequency_control(
    ess::EnergyStorageSystem,
    mode::FrequencyWattMode,
    meteredFrequency::Float64,
    nominalFrequency::Float64,
    t::Dates.DateTime,
    currentIterationPower::Float64
    )
    if meteredFrequency <= mode.highStoppingFrequency
        if mode.fwState.exceededTime === nothing
            mode.fwState.exceededTime = t
        elseif (t - mode.fwState.exceededTime) > mode.stopDelay
            clear_mode_state(mode, nothing)
            inactive_control(ess, mode, meteredFrequency, nominalFrequency, t, currentIterationPower)
        end
    end
    if mode.useSnapshotPower
        calculate_gradient_power = get_gradient_power_calculator(mode, currentIterationPower)
        gradientPower = calculate_gradient_power(percent_difference(meteredFrequency, nominalFrequency))
        mode.fwState.hysteresisValue = min(mode.fwState.hysteresisValue, gradientPower)
        commandPower = mode.useHysteresis ? mode.fwState.hysteresisValue : gradientPower        
    else
        frequencyPastStart = meteredFrequency - mode.highStartingFrequency
        powerLimit = p_max(ess) + (gradient * frequencyPastStart)
        commandPower = currentIterationPower > powerLimit ? powerLimit - currentIterationPower : 0.0
    end
    return commandPower
end

function low_frequency_control(
    ess::EnergyStorageSystem,
    mode::FrequencyWattMode,
    meteredFrequency::Float64,
    nominalFrequency::Float64,
    t::Dates.DateTime,
    currentIterationPower::Float64
    )
    if meteredFrequency >= mode.lowStoppingFrequency
        if mode.fwState.exceededTime === nothing
            mode.fwState.exceededTime = t
        elseif (t - mode.fwState.exceededTime) > mode.stopDelay
            clear_mode_state(mode, nothing)
            inactive_control(ess, mode, meteredFrequency, nominalFrequency, t, currentIterationPower)
        end
    end
    if mode.useSnapshotPower
        calculate_gradient_power = get_gradient_power_calculator(mode, currentIterationPower)
        gradientPower = calculate_gradient_power(percent_difference(meteredFrequency, nominalFrequency))
        mode.fwState.hysteresisValue = max(mode.fwState.hysteresisValue, gradientPower)
        commandPower = mode.useHysteresis ? mode.fwState.hysteresisValue : gradientPower        
    else
        frequencyPastStart = meteredFrequency - mode.lowStartingFrequency
        # TODO: Where does this gradient need to come from? The variable is currently undefined.
        powerLimit = p_min(ess) + (gradient * frequencyPastStart)
        commandPower = currentIterationPower < powerLimit ? powerLimit - currentIterationPower : 0.0
    end
    return commandPower  # TODO: This should actually have another step. The value calculated should have been percent of max power, not power.
end

function get_gradient_power_calculator(mode::FrequencyWattMode, currentIterationPower::Float64)
    dischargeGradient = mode.fwState.activeState == "HF" ? mode.highDischargeGradient : mode.lowDischargeGradient
    chargeGradient = mode.fwState.activeState == "HF" ? mode.highChargeGradient : mode.lowChargeGradient
    crossingDistance::Float64 = currentIterationPower >= 0 ? currentIterationPower / abs(dischargeGradient) : 0.0
    return deltaF -> min(deltaF, crossingDistance) * dischargeGradient + max(0.0, deltaF - crossingDistance) * chargeGradient
end

function clear_mode_state(mode::FrequencyWattMode, newMode::Union{String, Nothing})
    mode.fwState.activeState = newMode
    mode.fwState.exceededTime = nothing
    mode.fwState.hysteresisValue = 0.0
end

function percent_difference(x::Float64, y::Float64)
    # TODO: Should this really return a percentage (100x value)?  The equations look like it is a ratio but call it a percentage...
    return 2.0 * (x - y) / (x + y)
end