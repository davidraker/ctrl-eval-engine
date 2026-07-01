module CtrlEvalEngine
using AWSS3
using JSON
using Dates

export evaluate_controller,
    Series,
    PeriodSeries,
    PointSeries,
    TimeSeries,
    FixedIntervalTimeSeries,
    VariableIntervalTimeSeries,
    VariableIntervalPeriodTimeSeries,
    VariableIntervalPointTimeSeries,
    RepeatedTimeSeries,
    raw_vector,
    TimeFrame,
    TimeFrameRow,
    timestamps,
    get_values,
    start_time,
    end_time,
    duration,
    sample,
    upsample,
    integrate,
    cum_integrate,
    mean,
    std,
    get_period,
    extract,
    power,
    Progress,
    InvalidInput,
    InitializationFailure

include("types.jl")

cleanup(::Any) = nothing

function get_setting(inputDict::Dict)
    simStart = Dates.DateTime(inputDict["simStart"])
    simEnd = Dates.DateTime(inputDict["simEnd"])
    temperature =
        if inputDict["ambientTemperatureCharacteristics"]["temperatureVariationOverTime"] ===
           "constant"
            inputDict["ambientTemperatureCharacteristics"]["temperature"]
        else
            temperatureSequence =
                inputDict["ambientTemperatureCharacteristics"]["temperatureSequence"]
            timestamps = DateTime.(temperatureSequence["DateTime"])
            push!(timestamps, timestamps[end] + (timestamps[end] - timestamps[end-1]))
            VariableIntervalTimeSeries(timestamps, temperatureSequence["temperature_C"])
        end
    SimSetting(simStart, simEnd, temperature)
end

include("simulator/main.jl")
include("use-case/main.jl")
include("scheduler/main.jl")
include("realtime-controller/main.jl")

using .EnergyStorageSimulators
using .EnergyStorageUseCases
using .EnergyStorageScheduling
using .EnergyStorageRTControl

"""
    generate_output_dict(progress, useCases)

Generate the output dictionary according to `progress` and `useCases`.
"""
function generate_output_dict(
    progress::Progress,
    useCases::AbstractVector{<:UseCase},
    ess::EnergyStorageSystem,
)
    @debug "Calculating default metrics"
    netBenefit = mapreduce(uc -> calculate_net_benefit(progress, uc), +, useCases)
    simPeriodLengthInYear =
        (end_time(progress.operation) - start_time(progress.operation)) / Day(365)
    annualBenefit = netBenefit / simPeriodLengthInYear

    # Capital recovery factor
    discount = 0.0685
    cbaYears = 20
    CRF = discount + discount / ((1 + discount)^cbaYears - 1)

    pvBenefit = annualBenefit / CRF

    # Annual usage
    dischargedEnergyKwh = discharged_energy(progress.operation)
    annualDischargedEnergyKwh = dischargedEnergyKwh / simPeriodLengthInYear
    annualCycles = round(Int, annualDischargedEnergyKwh / e_max(ess))
    annualDischargedEnergyMwh = round(annualDischargedEnergyKwh / 1000; sigdigits = 3)
    annualUsageString =
        annualDischargedEnergyKwh ≥ 1000 ? "$annualDischargedEnergyMwh MWh" :
        "$(round(annualDischargedEnergyKwh, sigdigits=3)) kWh"

    annualCyclesString = "$annualCycles"
    energyLossKwh = charged_energy(progress.operation) - dischargedEnergyKwh

    endingSohPct = round(SOH(ess) * 100)

    @debug "Calculating use-case-specific metrics"
    metrics = mapreduce(
        uc -> calculate_metrics(progress.schedule, progress.operation, uc),
        vcat,
        useCases;
        init = [
            Dict(:label => "Annual Benefit", :value => annualBenefit, :type => "currency"),
            Dict(
                :label => "Present Value Benefit",
                :value => pvBenefit,
                :type => "currency",
            ),
            Dict(:label => "Annual Discharged Energy", :value => annualUsageString),
            Dict(:label => "Annual Cycles", :value => annualCyclesString),
            Dict(:label => "SOH Change", :value => "100% → $endingSohPct%"),
            Dict(
                :label => "Energy Loss",
                :value =>
                    energyLossKwh ≥ 1000 ?
                    "$(round(energyLossKwh / 1000, sigdigits=3)) MWh" :
                    "$(round(energyLossKwh, sigdigits=3)) kWh",
            ),
        ],
    )

    @debug "Generating data for time-series charts" useCases
    timeCharts = vcat(
        generate_chart_data(progress, useCases),
        EnergyStorageSimulators.bms_chart_data(ess, progress.operation),
    )
    outputDict = Dict{Symbol, Any}(:metrics => metrics, :timeCharts => timeCharts)
    bmsOutput = EnergyStorageSimulators.bms_output(ess, progress.operation)
    if bmsOutput !== nothing
        outputDict[:bms] = bmsOutput
    end
    return outputDict
end

function update_progress!(progress::Progress, t::Dates.DateTime, setting::SimSetting)
    progress.progressPct =
        min((t - setting.simStart) / (setting.simEnd - setting.simStart), 1.0) * 95.0 + 5.0
end

function update_operation_history!(
    opHistory::TimeFrame,
    t::Dates.DateTime,
    operatingPoint::NamedTuple,
)
    push!(opHistory, t, operatingPoint)
end

function update_schedule_history!(
    scheduleHistory::TimeFrame,
    currentSchedule::TimeFrame,
)
    append!(scheduleHistory, currentSchedule)
end

function update_schedule_period_progress!(
    spp::VariableIntervalTimeSeries,
    actualPowerKw,
    duration::Dates.Period,
)
    if !isempty(spp.value) && spp.value.vec[end] == actualPowerKw
        spp.t[end] += duration
    else
        push!(spp.value.vec, actualPowerKw)
        push!(spp.t, spp.t[end] + duration)
    end
end

function generate_chart_data(progress::Progress, useCases)
    defaultCharts = [
        Dict(
            :title => "ESS Operation",
            :height => "400px",
            :xAxis => Dict(:title => "Time"),
            :yAxisLeft => Dict(:title => "Power (kW)"),
            :yAxisRight => Dict(:title => "SOC (%)", :tickformat => ",.0%"),
            :data => [
                Dict(
                    :x => progress.schedule.t,
                    :y => column_data(progress.schedule, :powerKw),
                    :type => "interval",
                    :name => "Scheduled Power",
                ),
                Dict(
                    :x => progress.operation.t,
                    :y => column_data(progress.operation, :powerKw),
                    :type => "interval",
                    :line => Dict(:dash => :dot),
                    :name => "Actual Power",
                ),
                Dict(
                    :x => progress.schedule.t,
                    :y => column_data(progress.schedule, :SOC),
                    :type => "instance",
                    :name => "Scheduled SOC",
                    :yAxis => "right",
                ),
                Dict(
                    :x => progress.operation.t,
                    :y => column_data(progress.operation, :SOC),
                    :type => "instance",
                    :line => Dict(:dash => :dot),
                    :name => "Actual SOC",
                    :yAxis => "right",
                ),
            ],
        ),
    ]
    soh_data = column_data(progress.operation, :SOH)
    if soh_data[1] - soh_data[end] > 0.01
        push!(
            defaultCharts,
            Dict(
                :title => "Cumulative Degradation",
                :height => "200px",
                :xAxis => Dict(:title => "Time"),
                :yAxisLeft => Dict(:title => "SOH (%)", :tickformat => ",.0%"),
                :data => [
                    Dict(
                        :x => progress.operation.t,
                        :y => soh_data,
                        :type => "instance",
                        :name => "ESS State of Health",
                    ),
                ],
            ),
        )
    end
    mapreduce(
        uc -> use_case_charts(progress.schedule, progress.operation, uc),
        vcat,
        useCases;
        init = defaultCharts,
    )
end

"""
    evaluate_controller(inputDict)

Evaluate the performance of the controller specified in `inputDict`
"""
function evaluate_controller(inputDict, BUCKET_NAME, JOB_ID; debug = false)
    @info "Parsing and validating input data"
    setting = get_setting(inputDict)
    ess = get_ess(inputDict["selectedBatteryCharacteristics"], inputDict)
    useCases = get_use_cases(inputDict["selectedUseCasesCharacteristics"], setting)
    scheduler = EnergyStorageScheduling.get_scheduler(
        inputDict["selectedControlTypeCharacteristics"]["scheduler"],
        ess,
        useCases,
    )
    rtController = EnergyStorageRTControl.get_rt_controller(
        inputDict["selectedControlTypeCharacteristics"]["rtController"],
        ess,
        useCases,
    )

    t = setting.simStart
    progress = Progress(
        5.0,
        initialize_schedule_history(t, useCases),
        initialize_operation_history(t, ess),
    )
    if debug
        @debug "Progress updated" t progress
    else
        s3_put(BUCKET_NAME, "$JOB_ID/progress.json", JSON.json(progress))
    end
    lastProgressUpdateTime = now()

    outputProgress = deepcopy(progress)

    while t < setting.simEnd
        currentSchedule =
            EnergyStorageScheduling.schedule(ess, scheduler, useCases, t, outputProgress)
        update_schedule_history!(outputProgress.schedule, currentSchedule)
        for schedulePeriod in currentSchedule
            schedulePeriodEnd = min(end_time(schedulePeriod), setting.simEnd)
            spProgress = VariableIntervalTimeSeries([t], Float64[])
            while t < schedulePeriodEnd
                controlSequence =
                    control(ess, rtController, schedulePeriod, useCases, t, spProgress)
                for (powerSetpointKw, _, controlPeriodEnd) in controlSequence
                    controlDuration = controlPeriodEnd - t
                    operatingPoint = operate!(
                        ess,
                        powerSetpointKw,
                        controlDuration,
                        get_temperature(setting, t),
                    )
                    update_schedule_period_progress!(
                        spProgress,
                        operatingPoint.powerKw,
                        controlDuration,
                    )
                    t += controlDuration
                    update_operation_history!(outputProgress.operation, t, operatingPoint)
                    if t > schedulePeriodEnd
                        break
                    end
                end
                if now() > lastProgressUpdateTime + Second(5)
                    update_progress!(progress, t, setting)
                    if debug
                        @debug "Progress updated" t progress
                    else
                        s3_put(BUCKET_NAME, "$JOB_ID/progress.json", JSON.json(progress))
                    end
                    lastProgressUpdateTime = now()
                end
            end
        end
    end

    cleanup(scheduler)
    cleanup(rtController)
    cleanup(ess)

    @debug "Generating output..."
    return generate_output_dict(outputProgress, useCases, ess)
end

end
