"""
    EnergyStorageUseCases

The `EnergyStorageUseCases` provides type and functions for use cases
"""
module EnergyStorageUseCases

export UseCase,
    get_use_cases,
    initialize_schedule_history,
    calculate_metrics,
    calculate_net_benefit,
    use_case_charts,
    EnergyArbitrage,
    forecast_price,
    Regulation,
    RegulationPricePoint,
    RegulationOperationPoint,
    regulation_income,
    LoadFollowing,
    VariabilityMitigation,
    PeakLimiting,
    GenerationFollowing,
    DemandChargeReduction,
    demand_charge,
    demand_charge_periods_rates

abstract type UseCase end

using Dates
using CtrlEvalEngine
using CtrlEvalEngine: SimSetting, Progress, ScheduleHistory, OperationHistory
using LinearAlgebra
using JuMP
using JSON

JSON.lower(uc::UseCase) = Dict(
    :type => use_case_name(uc),
    :data => Dict(key => getfield(uc, key) for key ∈ fieldnames(typeof(uc))),
)

"""
    initialize_schedule_history(tStart::Dates.DateTime, useCases::AbstractVector{<:UseCase}, initialSoc::Float64 = 0.5)

Initialize a schedule history TimeFrame for tracking the planned operation schedule across multiple use cases.

The schedule history contains time-series data of the planned ESS operation including:

  - `:powerKw`: Scheduled charging/discharging power (PeriodSeries) - always included
  - `:SOC`: Scheduled state of charge (SOC) (PointSeries) - always included
  - Additional use-case-specific columns as determined by each use case's `initialize_extra_schedules` method

Each use case can contribute additional tracking columns (e.g., regulation capacity, peak demand)
by implementing their own `initialize_extra_schedules` method.

# Arguments

  - `tStart`: Starting timestamp for the schedule history
  - `useCases`: Vector of use cases to collect schedule columns from
  - `initialSoc`: Initial SOC for the ESS, defaulting to 0.5 (50% SOC)

# Returns

A `TimeFrame` with `:powerKw` and `:SOC` columns and any additional columns required by the use cases.
"""
function initialize_schedule_history(
    tStart::Dates.DateTime,
    useCases::AbstractVector{<:UseCase},
    initialSoc::Float64 = 0.5,
)
    scheduleColumns = mapreduce(
        initialize_extra_schedules,
        vcat,
        useCases;
        init = [(PeriodSeries{Float64}(), :powerKw), (PointSeries([initialSoc]), :SOC)],
    )

    allSeries = [col[1] for col in scheduleColumns]
    allHeaders = [col[2] for col in scheduleColumns]

    return TimeFrame([tStart], allSeries, allHeaders)
end

"""
    initialize_extra_schedules(useCase::UseCase)

Initialize additional schedule history columns specific to a use case.

This function allows different use case types to add custom tracking columns to the schedule history
beyond the default `:powerKw` column. The default implementation returns an empty vector, but
specific use cases can override this to add relevant metrics (e.g., `:regCapKw` for frequency
regulation).

# Arguments

  - `useCase`: Use case to initialize extra schedule columns for

# Returns

A vector of tuples `(series, header)` where:

  - `series`: Series object for the initial column data.
    PeriodSeries should be empty (will be populated during simulation),
    whereas PointSeries should contain exactly one value, which is the initial value.
  - `header`: Symbol representing the column name

# Example

A regulation use case might return:

```julia
[(PeriodSeries{Float64}(), :regCapKw)]
```
"""
initialize_extra_schedules(::UseCase) = Tuple{Series,Symbol}[]

"""
    calculate_net_benefit(progress::Progress, useCase::UseCase)

Calculate the net financial benefit for a use case. Default implementation returns `0.0`.
Specific use case types should override this method.

# Arguments

  - `progress::Progress`: Current simulation progress with operation history
  - `useCase::UseCase`: The use case to calculate benefits for

# Returns

`Float64`: Net financial benefit in currency units
"""
calculate_net_benefit(::Progress, ::UseCase) = 0.0

"""
    calculate_metrics(schedule::TimeFrame, operation::TimeFrame, useCase::UseCase)

Calculate performance metrics for a use case. Default implementation returns `[]`.
Specific use case types should override this method.

# Arguments

  - `schedule::TimeFrame`: Planned operation data
  - `operation::TimeFrame`: Actual operation history
  - `useCase::UseCase`: The use case to calculate metrics for

# Returns

`Vector`: Vector of metric dictionaries with `:name`, `:value`, and `:type` fields
"""
calculate_metrics(::TimeFrame, ::TimeFrame, ::UseCase) = []

"""
    use_case_charts(schedule::TimeFrame, operation::TimeFrame, useCase::UseCase)

Generate visualization charts for a use case. Default implementation returns `[]`.
Specific use case types should override this method.

# Arguments

  - `schedule::TimeFrame`: Planned operation data
  - `operation::TimeFrame`: Actual operation history
  - `useCase::UseCase`: The use case to generate charts for

# Returns

`Vector`: Vector of chart configuration dictionaries for plotting libraries
"""
use_case_charts(::TimeFrame, ::TimeFrame, ::UseCase) = []

include("energy-arbitrage.jl")
include("regulation.jl")
include("variability-mitigation.jl")
include("load-following.jl")
include("peak-limiting.jl")
include("generation-following.jl")
include("demand-charge-reduction.jl")

get_use_cases(inputDict::Dict, setting::SimSetting) = [
    if name === "Energy Arbitrage"
        EnergyArbitrage(config["data"], setting.simStart, setting.simEnd)
    elseif name === "Power Smoothing"
        VariabilityMitigation(config["data"], setting.simStart, setting.simEnd)
    elseif name === "Load Following"
        LoadFollowing(config["data"], setting.simStart, setting.simEnd)
    elseif name === "Generation Following"
        GenerationFollowing(config["data"], setting.simStart, setting.simEnd)
    elseif name === "Frequency Regulation"
        Regulation(config, setting.simStart, setting.simEnd)
    elseif name === "Demand Charge Reduction"
        DemandChargeReduction(config["data"], setting.simStart, setting.simEnd)
    else
        throw(InvalidInput("Unknown use case: $name"))
    end for (name, config) in inputDict
]

end