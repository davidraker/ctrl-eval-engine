"""
    EnergyStorageScheduling

The `EnergyStorageScheduling` provides type and functions related to the scheduling/dispatch of energy storage systems.
"""
module EnergyStorageScheduling

using Dates
using ..CtrlEvalEngine

export get_scheduler,
    schedule,
    create_schedule,
    create_schedule_period,
    average_power,
    ending_soc,
    regulation_capacity,
    OptScheduler,
    RLScheduler

abstract type Scheduler end

# Constructor function to create a Schedule (TimeFrame) with standard columns
function create_schedule(
    powerKw::Vector{Float64},
    tStart::Dates.DateTime;
    resolution::Dates.TimePeriod = Hour(1),
    SOC::Vector{Float64} = zeros(length(powerKw) + 1),
    regCapKw::Union{Nothing,Vector{Float64}} = nothing,
)
    timestamps = [tStart + resolution * i for i = 0:length(powerKw)]
    schSeries = [PeriodSeries(powerKw), PointSeries(SOC)]
    schHeaders = [:powerKw, :SOC]
    if !isnothing(regCapKw)
        push!(schSeries, PeriodSeries(regCapKw))
        push!(schHeaders, :regCapKw)
    end
    return TimeFrame(timestamps, schSeries, schHeaders)
end

create_schedule_period(p, tStart::Dates.DateTime; duration::Dates.Period = Hour(1)) =
    TimeFrameRow(TimeFrame([tStart, tStart + duration], [PeriodSeries([p])], [:powerKw]), 1)

# Helper functions for schedule-specific TimeFrameRow instances
average_power(tfr::TimeFrameRow) = tfr[:powerKw][1]
ending_soc(tfr::TimeFrameRow) = tfr[:SOC][1][2]
regulation_capacity(tfr::TimeFrameRow) = haskey(tfr, :regCapKw) ? tfr[:regCapKw][1] : 0.0

using ..CtrlEvalEngine.EnergyStorageSimulators
using ..CtrlEvalEngine.EnergyStorageUseCases

include("mock-scheduler.jl")
include("optimization-scheduler.jl")
include("manual-scheduler.jl")
include("RL-scheduler.jl")
include("rule-based.jl")
include("time-of-use.jl")
include("user-defined.jl")

struct IdleScheduler <: Scheduler
    interval::Dates.Period
end

schedule(
    ess::EnergyStorageSystem,
    scheduler::IdleScheduler,
    _,
    tStart::Dates.DateTime,
    ::Progress,
) = create_schedule([0.0], tStart; resolution = scheduler.interval, SOC = [SOC(ess), SOC(ess)])

"""
    get_scheduler(inputDict::Dict)

Create a scheduler of appropriate type from the input dictionary
"""
function get_scheduler(
    schedulerConfig::Dict,
    ess::EnergyStorageSystem,
    useCases::AbstractArray{<:UseCase},
)
    try
        schedulerType = schedulerConfig["type"]
        scheduler = if schedulerType == "mock"
            MockScheduler(Hour(1), Hour(6), get(schedulerConfig, "sleepSeconds", 0))
        elseif schedulerType == "schedulerOptimization"
            endSocInput = get(schedulerConfig, "endSocPct", nothing)
            endSoc = if isnothing(endSocInput)
                nothing
            elseif endSocInput isa Real
                endSocInput / 100
            else
                (endSocInput[1], endSocInput[2]) ./ 100
            end
            res = Minute(
                round(
                    Int,
                    convert(Minute, Hour(1)).value *
                    schedulerConfig["scheduleResolutionHrs"],
                ),
            )
            interval = Minute(
                round(Int, convert(Minute, Hour(1)).value * schedulerConfig["intervalHrs"]),
            )
            powerLimitPct = get(schedulerConfig, "powerLimitPct", 100)
            if isnothing(powerLimitPct)
                powerLimitPct = 100
            end
            OptScheduler(
                res,
                interval,
                ceil(
                    Int64,
                    schedulerConfig["optWindowLenHrs"] /
                    schedulerConfig["scheduleResolutionHrs"],
                ),
                endSoc;
                minNetLoadKw = get(schedulerConfig, "minNetLoadKw", nothing),
                powerLimitPu = powerLimitPct / 100,
            )
        elseif schedulerType == "schedulerML"
            res = Minute(
                round(
                    Int,
                    convert(Minute, Hour(1)).value *
                    get(schedulerConfig, "scheduleResolutionHrs", 1),
                ),
            )
            RLScheduler(res, schedulerConfig, ess)
        elseif schedulerType == "idle"
            IdleScheduler(Hour(24))
        elseif schedulerType == "manual" || schedulerType == "manualScheduler"
            res = Minute(
                round(
                    Int,
                    convert(Minute, Hour(1)).value *
                    get(schedulerConfig, "scheduleResolutionHrs", 1),
                ),
            )
            ManualScheduler(float.(schedulerConfig["powerKw"]), Dates.DateTime(2000, 1, 1), res)
        elseif schedulerType == "rule"
            res = Minute(
                round(
                    Int,
                    convert(Minute, Hour(1)).value *
                    schedulerConfig["scheduleResolutionHrs"],
                ),
            )
            interval = Minute(
                round(
                    Int,
                    convert(Minute, Hour(1)).value * schedulerConfig["optWindowLenHrs"],
                ),
            )
            RuleBasedScheduler(res, interval, schedulerConfig)
        elseif schedulerType == "TOU"
            res = Minute(
                round(
                    Int,
                    convert(Minute, Hour(1)).value *
                    schedulerConfig["scheduleResolutionHrs"],
                ),
            )
            interval = Minute(
                round(Int, convert(Minute, Hour(1)).value * schedulerConfig["intervalHrs"]),
            )
            TimeOfUseScheduler(res, interval, schedulerConfig["ruleSet"])
        elseif schedulerType == "userDefinedScheduler"
            UserDefinedScheduler(schedulerConfig, ess, useCases)
        else
            throw(InvalidInput("Invalid scheduler type: $schedulerType"))
        end
        return scheduler
    catch e
        if e isa KeyError
            throw(InvalidInput("Missing key in scheduler config - \"$(e.key)\""))
        else
            rethrow()
        end
    end
end

end
