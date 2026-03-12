"""
    TimeOfUseRuleSet

`TimeOfUseRuleSet` represents a set of target SOCs corresponding to ranges of price.
The target value is defined as `target[i]` during the `i`th price range (from `price[i-1]` to `price[i]`),
where `1 ≤ i ≤ length(target)` and `length(price) + 1 == length(target)`.
The implied first and last price thresholds, i.e., `price[0]` and `price[length(target)]` are -Inf and Inf, respectively.
A target of `nothing` means to remain the current SOC.
"""
struct TimeOfUseRuleSet
    price::Vector{Float64}
    target::Vector{Union{Float64,Nothing}}
    TimeOfUseRuleSet(price, target) =
        length(price) + 1 == length(target) ? new(price, target) :
        error("Incompatible lengths")
end

Base.iterate(rs::TimeOfUseRuleSet, index = 1) =
    index > length(rs.target) || index + 1 > length(rs.price) ? nothing :
    ((rs.target[index], rs.price[index], rs.price[index+1]), index + 1)

Base.eltype(::Type{TimeOfUseRuleSet}) = Tuple{Float64,Float64,Float64}
Base.length(rs::TimeOfUseRuleSet) = min(length(rs.target), length(rs.price) - 1)

"""
    get_target(rs, price)

Return the target of `rs` at `price` and the defined price range that encloses `price`.
"""
get_target(rs::TimeOfUseRuleSet, price::Float64) = begin
    if price ≥ rs.price[1] && price < rs.price[end]
        index = findfirst(x -> x > price, rs.price) - 1
        (rs.target[index+1], rs.price[index], rs.price[index+1])
    elseif price < rs.price[1]
        (rs.target[1], -Inf, rs.price[1])
    else
        (rs.target[end], rs.price[end], Inf)
    end
end

struct TimeOfUseScheduler <: Scheduler
    resolution::Dates.Period
    interval::Dates.Period
    rule_set::TimeOfUseRuleSet
end

TimeOfUseScheduler(resolution::Dates.Period, interval::Dates.Period, ruleSet::AbstractDict) =
    TimeOfUseScheduler(
        resolution,
        interval,
        TimeOfUseRuleSet(
            ruleSet["PriceThreshold"][1:length(ruleSet["TargetSocPct"])-1] ./ 1000, # convert from $/MWh to $/kWh
            ruleSet["TargetSocPct"],
        ),
    )

"""
    schedule(ess, TimeOfUseScheduler, useCases, t)

Schedule the operation of `ess` with `TimeOfUseScheduler` given `useCases`
"""
function schedule(
    ess,
    scheduler::TimeOfUseScheduler,
    useCases::AbstractVector{<:UseCase},
    tStart::Dates.DateTime,
    ::Progress,
)
    eaIdx = findfirst(uc -> uc isa EnergyArbitrage, useCases)
    if isnothing(eaIdx)
        error("No supported use case is found by TimeOfUseScheduler")
    end
    ucEA = useCases[eaIdx]
    scheduleLength =
        Int(ceil(scheduler.interval, scheduler.resolution) / scheduler.resolution)
    current_soc = SOC(ess)
    schedule_vector = Vector{Float64}(undef, scheduleLength)
    soc_vector = Vector{Float64}(undef, scheduleLength + 1)
    soc_vector[1] = current_soc
    for i = 1:scheduleLength
        step_start = tStart + (scheduler.resolution * (i - 1))
        price, _, tou_end = get_period(forecast_price(ucEA), step_start)
        target, _, _ = get_target(scheduler.rule_set, price)
        target = isnothing(target) ? current_soc : target / 100.0
        # TODO: This should really get the target for all periods of the use case so that it can determine when the next __change__ in the mode is, rather than assuming each period to be atomic.
        efficiency = sqrt(ηRT(ess))
        batt_energy_change = (target - current_soc) * e_max(ess)
        energy_change =
            batt_energy_change > 0 ? batt_energy_change / efficiency :
            batt_energy_change * efficiency
        schedule_vector[i] = max(
            p_min(ess),
            min(
                p_max(ess),
                -energy_change / (
                    (isnothing(tou_end) ? scheduler.resolution : tou_end - step_start) /
                    Dates.Hour(1)
                ),
            ),
        )
        soc_vector[i+1] =
            current_soc =
                current_soc -
                (
                    schedule_vector[i] > 0 ? schedule_vector[i] / efficiency :
                    schedule_vector[i] * efficiency
                ) / e_max(ess)
    end
    return create_schedule(
        schedule_vector,
        tStart;
        resolution = scheduler.resolution,
        SOC = soc_vector,
    )
end
