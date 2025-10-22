
struct EnergyArbitrage <: UseCase
    actualPrice::TimeSeries
    forecastPrice::Union{TimeSeries,Nothing}
end

EnergyArbitrage(actualPrice::TimeSeries) = EnergyArbitrage(actualPrice, nothing)

"""
    EnergyArbitrage(input)

Construct an `EnergyArbitrage` object from `input` dictionary or array
"""
EnergyArbitrage(input::Dict) = EnergyArbitrage(
    FixedIntervalTimeSeries(
        DateTime(input["actualEnergyPrice"]["Time"][1]),
        DateTime(input["actualEnergyPrice"]["Time"][2]) -
        DateTime(input["actualEnergyPrice"]["Time"][1]),
        float.(input["actualEnergyPrice"]["EnergyPrice_per_MWh"]) ./ 1000,
    ),
    if get(input, "forecastEnergyPrice", nothing) === nothing
        nothing
    else
        FixedIntervalTimeSeries(
            DateTime(input["forecastEnergyPrice"]["Time"][1]),
            DateTime(input["forecastEnergyPrice"]["Time"][2]) -
            DateTime(input["forecastEnergyPrice"]["Time"][1]),
            float.(input["forecastEnergyPrice"]["EnergyPrice_per_MWh"]) ./ 1000,
        )
    end,
)

EnergyArbitrage(input::Dict, tStart::DateTime, tEnd::DateTime) = EnergyArbitrage(
    extract(
        FixedIntervalTimeSeries(
            DateTime(input["actualEnergyPrice"]["Time"][1]),
            DateTime(input["actualEnergyPrice"]["Time"][2]) -
            DateTime(input["actualEnergyPrice"]["Time"][1]),
            float.(input["actualEnergyPrice"]["EnergyPrice_per_MWh"]) ./ 1000,
        ),
        tStart,
        tEnd,
    ),
    if get(input, "forecastEnergyPrice", nothing) === nothing
        nothing
    else
        extract(
            FixedIntervalTimeSeries(
                DateTime(input["forecastEnergyPrice"]["Time"][1]),
                DateTime(input["forecastEnergyPrice"]["Time"][2]) -
                DateTime(input["forecastEnergyPrice"]["Time"][1]),
                float.(input["forecastEnergyPrice"]["EnergyPrice_per_MWh"]) ./ 1000,
            ),
            tStart,
            tEnd,
        )
    end,
)

use_case_name(ucEA::EnergyArbitrage) = "Energy Arbitrage"

forecast_price(ucEA::EnergyArbitrage) =
    isnothing(ucEA.forecastPrice) ? ucEA.actualPrice : ucEA.forecastPrice

calculate_net_benefit(progress::Progress, ucEA::EnergyArbitrage) = begin
    @debug "Calculation Energy Arbitrage benefit" powerLen=length(power(progress.operation)) priceLen=length(ucEA.actualPrice)
    power(progress.operation) ⋅ ucEA.actualPrice
end

"""
    calculate_metrics(operation, useCase)

Summarize the benefit and cost associated with `useCase` given `operation`
"""
function calculate_metrics(
    ::TimeFrame,
    operation::TimeFrame,
    ucEA::EnergyArbitrage,
)
    @debug "Calculating metrics for Energy Arbitrage"
    return [
        Dict(:sectionTitle => "Energy Arbitrage"),
        Dict(
            :label => "Net Income",
            :value => power(operation) ⋅ ucEA.actualPrice,
            :type => "currency",
        ),
    ]
end

use_case_charts(sh::TimeFrame, op::TimeFrame, ucEA::EnergyArbitrage) = begin
    @debug "Generating time series charts for Energy Arbitrage"

    cumIncome = cum_integrate(power(op) * ucEA.actualPrice)

    priceTraces = if isnothing(ucEA.forecastPrice)
        [
            Dict(
                :x => timestamps(ucEA.actualPrice),
                :y => raw_vector(ucEA.actualPrice),
                :type => "interval",
                :name => "Energy Price",
                :yAxis => "right",
            ),
        ]
    else
        [
            Dict(
                :x => timestamps(ucEA.forecastPrice),
                :y => raw_vector(ucEA.forecastPrice),
                :type => "interval",
                :name => "Forecast Energy Price",
                :yAxis => "right",
            ),
            Dict(
                :x => timestamps(ucEA.actualPrice),
                :y => raw_vector(ucEA.actualPrice),
                :type => "interval",
                :line => Dict(:dash => :dot),
                :name => "Actual Energy Price",
                :yAxis => "right",
            ),
        ]
    end

    [
        Dict(
            :title => "Energy Arbitrage",
            :height => "350px",
            :yAxisLeft => Dict(:title => "Power (kW)"),
            :yAxisRight => Dict(:title => raw"Price ($/kWh)"),
            :data => [
                Dict(
                    :x => sh.t,
                    :y => raw_vector(sh[:powerKw]),
                    :type => "interval",
                    :name => "Scheduled Power",
                    :line => Dict(:dash => :dash),
                ),
                Dict(
                    :x => op.t,
                    :y => raw_vector(op[:powerKw]),
                    :type => "interval",
                    :name => "Actual Power",
                ),
                priceTraces...,
            ],
        ),
        Dict(
            :height => "300px",
            :xAxis => Dict(:title => "Time"),
            :yAxisLeft => Dict(:title => raw"Cumulative Net Income ($)"),
            :data => [
                Dict(
                    :x => timestamps(cumIncome),
                    :y => raw_vector(cumIncome),
                    :type => "instance",
                ),
            ],
        ),
    ]
end