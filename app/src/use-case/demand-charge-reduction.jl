
abstract type DemandChargeRateStructure end

struct FlatDemandChargeRateStructure <: DemandChargeRateStructure
    rate::Float64
end

struct MonthlyDemandChargeRateStructure <: DemandChargeRateStructure
    monthlyRates::Vector{Float64}
end

# TODO: TOU demand charge rate structure
struct TOUDemandChargeRateStructure <: DemandChargeRateStructure end

struct DemandChargeReduction <: UseCase
    rateStructure::DemandChargeRateStructure
    loadForecastKw15min::FixedIntervalTimeSeries
end

function DemandChargeReduction(
    config::AbstractDict,
    simStart::Dates.DateTime,
    simEnd::Dates.DateTime,
)
    loadForecastKw15min = extract(
        FixedIntervalTimeSeries(
            DateTime(config["loadForecast15min"]["Timestamp"][1]),
            Minute(15),
            float.(config["loadForecast15min"]["Load_kW"]),
        ),
        simStart,
        simEnd,
    )
    if config["rate"] isa Number
        DemandChargeReduction(
            FlatDemandChargeRateStructure(config["rate"]),
            loadForecastKw15min,
        )
    elseif config["rate"] isa Vector
        DemandChargeReduction(
            MonthlyDemandChargeRateStructure(float.(config["rate"])),
            loadForecastKw15min,
        )
    end
end

use_case_name(ucDCR::DemandChargeReduction) = "Demand Charge Reduction"

function demand_charge(rateStructure::FlatDemandChargeRateStructure, load::TimeSeries)
    monthStart = floor(start_time(load), Minute(15))
    monthEnd = firstdayofmonth(monthStart + Month(1))
    demandCharge = 0
    while monthEnd ≤ end_time(load)
        # For each month except the last incomplete month
        loadMonth15min = mean(load, monthStart:Minute(15):monthEnd)
        monthPeak = maximum(loadMonth15min)
        demandCharge += monthPeak * rateStructure.rate
        monthStart = monthEnd
        monthEnd = firstdayofmonth(monthStart + Month(1))
    end

    if monthStart < end_time(load)
        # Last incomplete month
        monthEnd = ceil(end_time(load), Minute(15))
        loadMonth15min = mean(load, monthStart:Minute(15):monthEnd)
        monthPeak = maximum(loadMonth15min)
        demandCharge += monthPeak * rateStructure.rate
    end
    return demandCharge
end

function demand_charge(rateStructure::MonthlyDemandChargeRateStructure, load::TimeSeries)
    monthStart = floor(start_time(load), Minute(15))
    monthEnd = firstdayofmonth(monthStart + Month(1))
    demandCharge = 0
    while monthEnd ≤ end_time(load)
        # For each month except the last incomplete month
        loadMonth15min = mean(load, monthStart:Minute(15):monthEnd)
        monthPeak = maximum(loadMonth15min)
        demandCharge += monthPeak * rateStructure.monthlyRates[month(monthStart)]
        monthStart = monthEnd
        monthEnd = firstdayofmonth(monthStart + Month(1))
    end

    if monthStart < end_time(load)
        # Last incomplete month
        monthEnd = ceil(end_time(load), Minute(15))
        loadMonth15min = mean(load, monthStart:Minute(15):monthEnd)
        monthPeak = maximum(loadMonth15min)
        demandCharge += monthPeak * rateStructure.monthlyRates[month(monthStart)]
    end
    return demandCharge
end

demand_charge(ucDCR::DemandChargeReduction, extraPower::TimeSeries) =
    demand_charge(ucDCR.rateStructure, ucDCR.loadForecastKw15min - extraPower)

function demand_charge_periods_rates(
    rateStructure::FlatDemandChargeRateStructure,
    netLoad::TimeSeries,
)
    months = []
    rates = []
    monthStart = floor(start_time(netLoad), Minute(15))
    monthEnd = firstdayofmonth(monthStart + Month(1))
    while monthEnd ≤ end_time(netLoad)
        # For each month except the last incomplete month
        loadMonth15min = mean(netLoad, monthStart:Minute(15):monthEnd)
        push!(months, [get_values(loadMonth15min)])
        push!(rates, [rateStructure.rate])
        monthStart = monthEnd
        monthEnd = firstdayofmonth(monthStart + Month(1))
    end

    if monthStart < end_time(netLoad)
        # Last incomplete month
        monthEnd = ceil(end_time(netLoad), Minute(15))
        loadMonth15min = mean(netLoad, monthStart:Minute(15):monthEnd)
        push!(months, [get_values(loadMonth15min)])
        push!(rates, [rateStructure.rate])
    end
    @debug "Exiting demand_charge_periods_rates" netLoad months rates
    return months, rates
end

function demand_charge_periods_rates(
    rateStructure::MonthlyDemandChargeRateStructure,
    netLoad::TimeSeries,
)
    months = []
    rates = []
    monthStart = floor(start_time(netLoad), Minute(15))
    monthEnd = firstdayofmonth(monthStart + Month(1))
    while monthEnd ≤ end_time(netLoad)
        # For each month except the last incomplete month
        loadMonth15min = mean(netLoad, monthStart:Minute(15):monthEnd)
        push!(months, [get_values(loadMonth15min)])
        push!(rates, [rateStructure.monthlyRates[month(monthStart)]])
        monthStart = monthEnd
        monthEnd = firstdayofmonth(monthStart + Month(1))
    end

    if monthStart < end_time(netLoad)
        # Last incomplete month
        monthEnd = ceil(end_time(netLoad), Minute(15))
        loadMonth15min = mean(netLoad, monthStart:Minute(15):monthEnd)
        push!(months, [get_values(loadMonth15min)])
        push!(rates, [rateStructure.monthlyRates[month(monthStart)]])
    end
    return months, rates
end

calculate_net_benefit(progress::Progress, ucDCR::DemandChargeReduction) = begin
    @debug "Calculation DCR benefit"
    demand_charge(ucDCR.rateStructure, ucDCR.loadForecastKw15min) - demand_charge(ucDCR, power(progress.operation))
end

function calculate_metrics(
    ::TimeFrame,
    operation::TimeFrame,
    ucDCR::DemandChargeReduction,
)
    @debug "Calculating metrics for Demand Charge Reduction"
    return [
        Dict(:sectionTitle => "Demand Charge Reduction"),
        Dict(
            :label => "Demand Charge w/o ESS",
            :value => demand_charge(ucDCR.rateStructure, ucDCR.loadForecastKw15min),
            :type => "currency",
        ),
        Dict(
            :label => "Demand Charge w/ ESS",
            :value => demand_charge(ucDCR, power(operation)),
            :type => "currency",
        ),
    ]
end

use_case_charts(::TimeFrame, op::TimeFrame, ucDCR::DemandChargeReduction) =
    begin
        @debug "Generating time series charts for Demand Charge Reduction"

        originalLoadTrace = Dict(
            :x => timestamps(ucDCR.loadForecastKw15min),
            :y => raw_vector(ucDCR.loadForecastKw15min),
            :type => "interval",
            :name => "Native Load",
        )

        netLoad = ucDCR.loadForecastKw15min - power(op)

        netLoadTrace = Dict(
            :x => timestamps(netLoad),
            :y => raw_vector(netLoad),
            :type => "interval",
            :name => "Net Load",
        )

        [
            Dict(
                :title => "Demand Charge Reduction",
                :height => "350px",
                :yAxisLeft => Dict(:title => "Power (kW)"),
                :data => [originalLoadTrace, netLoadTrace],
            ),
        ]
    end
