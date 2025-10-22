using Combinatorics

struct RuleBasedScheduler <: Scheduler
    resolution::Dates.Period
    interval::Dates.Period
    curtailment_ratio::Float64
    soc_thresholds::Dict
    factor::Float64
end

RuleBasedScheduler(res::Dates.Period, interval::Dates.Period, config::Dict) =
    RuleBasedScheduler(
        res,
        interval,
        get(config, "curtailment_ratio", 0.1),
        get(config, "soc_thresholds", Dict("high" => 0.7, "low" => 0.3)),
        get(config, "factor", 0.5),
    )

function schedule(
    ess::EnergyStorageSystem,
    scheduler::RuleBasedScheduler,
    useCases::AbstractArray{<:UseCase},
    tStart::DateTime,
    ::Progress,
)
    curtailment_ratio = 0.1
    soc_thresholds = Dict("high" => 70, "low" => 30)
    scheduleLength =
        Int(ceil(scheduler.interval, scheduler.resolution) / scheduler.resolution)

    eaIdx = findfirst(uc -> uc isa EnergyArbitrage, useCases)
    if isnothing(eaIdx)
        optimal_power = zeros(scheduleLength)
        optimal_states = fill(SOC(ess), scheduleLength)
    else
        ucEA = useCases[eaIdx]

        price = sample(
            forecast_price(ucEA),
            range(tStart; step = scheduler.resolution, length = scheduleLength),
        )

        feasible_theta = [comb for comb in combinations(price, 2) if comb[1] < comb[2]]
        all_state_trans = zeros(scheduleLength, length(feasible_theta)) #size(price_forecast, 2)
        all_power = zeros(scheduleLength, length(feasible_theta))
        all_total_cost = zeros(length(feasible_theta))

        for i in eachindex(feasible_theta)
            theta_low = feasible_theta[i][1]
            theta_high = feasible_theta[i][2]
            stateK0 = SOC(ess)
            cost = zeros(scheduleLength)

            for h = 1:scheduleLength
                if price[h] <= theta_low
                    batt = min(p_max(ess), e_max(ess) * (1 - stateK0) / ηRT(ess))
                    stateK0 = stateK0 + (batt * ηRT(ess)) / e_max(ess)
                    cost_cal = -batt * price[h]
                    output = -batt
                elseif price[h] >= theta_high
                    batt = min(
                        p_max(ess),
                        max(0, (stateK0 * e_max(ess) - e_min(ess)) * ηRT(ess)),
                    )
                    stateK0 = stateK0 - batt / (e_max(ess) * ηRT(ess))
                    cost_cal = batt * price[h]
                    output = batt
                else
                    batt = 0
                    stateK0 = stateK0
                    cost_cal = batt * price[h]
                    output = batt
                end
                cost[h] = cost_cal
                all_state_trans[h, i] = stateK0
                all_power[h, i] = output
            end

            all_total_cost[i] = sum(cost)
        end

        _, optimal_index = findmax(all_total_cost)
        optimal_power = all_power[:, optimal_index]
        optimal_states = all_state_trans[:, optimal_index]
    end
    @debug "optimal states before DCR" optimal_states maxlog = 2

    dcrIdx = findfirst(uc -> uc isa DemandChargeReduction, useCases)
    if !isnothing(dcrIdx)
        ucDCR = useCases[dcrIdx]
        load_forecast = get_values(
            mean(
                ucDCR.loadForecastKw15min,
                range(tStart; length = 25, step = scheduler.resolution),
            ),
        )
        optimal_power, optimal_states = rlDcr(
            load_forecast,
            optimal_power,
            optimal_states,
            ess,
            scheduler.curtailment_ratio,
            scheduler.soc_thresholds,
            scheduler.factor,
        )
    end

    return create_schedule(
        optimal_power,
        tStart;
        resolution = scheduler.resolution,
        SOC = [SOC(ess), optimal_states...],
    )
end

function rlDcr(
    load::Vector{Float64},
    optimal_power,
    optimal_states::Vector{Float64},
    ess,
    curtailment_ratio::Float64,
    soc_thresholds::Dict,
    factor::Float64 = 0.5,
)
    peak_power = maximum(load)
    threshold = (1.0 - curtailment_ratio) * peak_power
    diff = 0
    for (hour, schedule_power) in enumerate(load)
        if hour == 1
            prev_states = SOC(ess)
        else
            prev_states = optimal_states[hour-1]
        end
        if schedule_power > threshold
            # Your code to discharge the battery goes here
            if prev_states > soc_thresholds["high"]
                optimal_power[hour] = schedule_power - threshold
            elseif soc_thresholds["high"] >= prev_states >= soc_thresholds["low"]
                optimal_power[hour] = (schedule_power - threshold)
            else
                optimal_power[hour] = factor * (schedule_power - threshold)
            end

            new_optimal_states = prev_states - optimal_power[hour] / (e_max(ess) * ηRT(ess))
            @debug "in DCR, new_optimal_states" new_optimal_states maxlog = 24
            diff = optimal_states[hour] - new_optimal_states
            optimal_states[hour] = new_optimal_states
            @debug "in DCR, if schedule_power > threshold optimal_states" optimal_states hour maxlog =
                24
        else
            if prev_states > soc_thresholds["high"]
                optimal_power[hour] = 0
            elseif soc_thresholds["high"] >= prev_states >= soc_thresholds["low"]
                optimal_power[hour] = factor * (schedule_power - threshold)
            else
                optimal_power[hour] = (schedule_power - threshold)
            end
            new_optimal_states = prev_states
            optimal_states[hour] = new_optimal_states + diff
            @debug "in DCR, if schedule_power < threshold optimal_states" optimal_states hour maxlog =
                24
            diff = 0
        end
    end
    return optimal_power, optimal_states
end
