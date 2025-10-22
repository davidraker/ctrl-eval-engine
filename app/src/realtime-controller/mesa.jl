# module MesaEss

using Dates
using CtrlEvalEngine.EnergyStorageSimulators
using CtrlEvalEngine.EnergyStorageUseCases: UseCase, LoadFollowing
using CtrlEvalEngine.EnergyStorageScheduling: create_schedule_period

# export MesaController, MesaMode, Vertex, VertexCurve, RampParams, apply_energy_limits, apply_ramps, apply_time_constants, control
abstract type MesaMode end

mutable struct MesaModeParams
    priority::Int64
    timeWindow::Union{Dates.Second, Nothing}
    rampTime::Union{Dates.Second, Nothing}
    reversionTimeout::Union{Dates.Second, Nothing}
    modeWIP::Union{FixedIntervalTimeSeries, Nothing}
end

function MesaModeParams(priority)
    timeWindow = nothing
    rampTime = nothing
    reversionTimeout = nothing
    wip = nothing
    return MesaModeParams(priority, timeWindow, rampTime, reversionTimeout, wip)
end

function MesaModeParams(priority, timeWindow, rampTime, reversionTimeout)
    wip = nothing
    return MesaModeParams(priority, timeWindow, rampTime, reversionTimeout, wip)
end

mutable struct MesaController <: RTController
    modes::Vector{MesaMode}
    resolution::Dates.Period
    wip::Union{FixedIntervalTimeSeries, Nothing}
end

function MesaController(modes, resolution)
    wip = nothing
    return MesaController(modes, resolution, wip)
end

struct Vertex
    x::Float64
    y::Float64
end

struct VertexCurve
    vertices::Array{Vertex}
end 

struct RampParams
    rampUpTimeConstant::Union{Dates.Second, Nothing}
    rampDownTimeConstant::Union{Dates.Second, Nothing}
    dischargeRampUpRate::Union{Float64, Nothing}  # The ramp rates are in units of a tenth of a percent per second -- i.e. divide by 1000 in constructor to get and store multiplier.
    dischargeRampDownRate::Union{Float64, Nothing}
    chargeRampUpRate::Union{Float64, Nothing}
    chargeRampDownRate::Union{Float64, Nothing}
end

function RampParams(rampUpTimeConstant, rampDownTimeConstant)
    return RampParams(rampUpTimeConstant, rampDownTimeConstant, nothing, nothing, nothing, nothing)
end

function RampParams(dischargeRampUpRate, dischargeRampDownRate, chargeRampUpRate, chargeRampDownRate)
    return RampParams(nothing, nothing, dischargeRampUpRate, dischargeRampDownRate, chargeRampUpRate, chargeRampDownRate)
end

function apply_time_constants(
    ess::EnergyStorageSystem,
    rampParams::Float64,
    currentPower::Float64,
    targetPower::Float64
)
    # Using time constants, not ramps.
    # timeSinceStart = currentTime - startTime
    # timeUntilEnd = endTime - currentTime
    allowedPowerChange = 0.0
    return currentPower + allowedPowerChange
end

function apply_ramps(
    ess::EnergyStorageSystem,
    rampParams::RampParams,
    currentPower::Float64,
    targetPower::Float64, 
    )
    # TODO: Ramp rates being in kW/s, they should be multiplied by the resolution, but how does this work with longer resolutions, as it will just jump?
    # TODO: Assuming ramp rate is percentage per second of p_max or p_min. The actual units in DNP3 spec are just percent per second. 
    #        Should this be percent of requested jump in power per second instead?
    if targetPower > currentPower && targetPower >= 0  # TODO: This assumes percent per second refers to percent of max/min power.
        allowedPowerChange = min(targetPower - currentPower, rampParams.dischargeRampUpRate / 1000  * p_max(ess))
    elseif targetPower < currentPower && targetPower >= 0
        allowedPowerChange = min(targetPower - currentPower, rampParams.dischargeRampDownRate / 1000 * p_max(ess))
    elseif targetPower > currentPower && targetPower < 0
        allowedPowerChange = max(targetPower - currentPower, rampParams.chargeRampUpRate / 1000 * p_min(ess))
    elseif targetPower < currentPower && targetPower < 0
        allowedPowerChange = max(targetPower - currentPower, rampParams.chargeRampDownRate / 1000 * p_min(ess))
    else
        allowedPowerChange = 0.0
    end
    return currentPower + allowedPowerChange
end

function apply_energy_limits(
    ess::EnergyStorageSystem,
    power::Float64,
    duration::Dates.Period, 
    minReserve::Union{Float64, Nothing}=nothing, 
    maxReserve::Union{Float64, Nothing}=nothing
    )
    minEnergy = minReserve ≠ nothing ? minReserve / 100 * e_max(ess) : e_min(ess)
    maxEnergy = maxReserve ≠ nothing ? maxReserve / 100 * e_max(ess) : e_max(ess)
    proposedNewEnergy = energy_state(ess) + (power * (duration / Hour(1)))
    if proposedNewEnergy > maxEnergy
        return (maxEnergy - energy_state(ess)) / (duration / Hour(1))
    elseif proposedNewEnergy < minEnergy
        return (minEnergy - energy_state(ess)) / (duration / Hour(1))
    else
        return power
    end
end

function previous_WIP(mode::MesaMode)
    wipLength = length(mode.params.modeWIP.value)
    previousIdx = wipLength > 1 ? wipLength - 1 : 1
    return mode.params.modeWIP.value[previousIdx]
end

function control(
    ess::EnergyStorageSystem,
    controller::MesaController,
    schedulePeriod::TimeFrameRow,
    useCases::AbstractVector{<:UseCase},
    t::Dates.DateTime,
    spProgress::VariableIntervalTimeSeries,
)
    # TODO: Implement handling of shared parameters which all modes have.

    # Initialize WIP series:
    if controller.wip === nothing
        controller.wip = FixedIntervalTimeSeries(t, controller.resolution, [0.0])
    else
        push!(controller.wip.value, 0.0)
    end
    # Call each mode in order of priority:
    sort!(controller.modes, by=m->m.params.priority)
    p = 0.0
    for mode in controller.modes
        if mode.params.modeWIP === nothing
            mode.params.modeWIP = FixedIntervalTimeSeries(t, controller.resolution, [0.0])
        else
            push!(mode.params.modeWIP.value, 0.0)
        end    
        modePower = modecontrol(mode, ess, controller, schedulePeriod, useCases, t, spProgress, p)
        mode.params.modeWIP.value[end] = modePower
        p = p + modePower
    end
    # Apply limits to the output before controlling:
    essLimitedPower = min(max(p, p_min(ess)), p_max(ess))
    energyLimitedPower = apply_energy_limits(ess, essLimitedPower, Dates.Second(controller.resolution))
    controller.wip.value[end] = energyLimitedPower
    return FixedIntervalTimeSeries(t, controller.resolution, [energyLimitedPower])
end

include("mesa-modes/mesa-active-power-limit-mode.jl")
include("mesa-modes/mesa-active-power-smoothing-mode.jl")
include("mesa-modes/mesa-active-response-mode.jl")
include("mesa-modes/mesa-agc-mode.jl")
include("mesa-modes/mesa-charge-discharge-storage-mode.jl")
include("mesa-modes/mesa-frequency-watt-mode.jl")
include("mesa-modes/mesa-volt-watt-mode.jl")
# end
