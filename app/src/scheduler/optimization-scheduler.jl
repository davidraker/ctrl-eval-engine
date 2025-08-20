
using JuMP
using LinearAlgebra
using HiGHS

struct OptScheduler <: Scheduler
    resolution::Dates.Period
    interval::Dates.Period
    optWindow::Int64
    endSoc::Union{Tuple{Float64,Float64},Nothing}
    powerLimitPu::Float64
    minNetLoadKw::Union{Float64,Nothing}
    regulationReserve::Float64
end

OptScheduler(
    res,
    interval,
    win,
    es = nothing;
    powerLimitPu = 1,
    minNetLoadKw = nothing,
    regulationReserve = 0.5,
) = OptScheduler(res, interval, win, es, powerLimitPu, minNetLoadKw, regulationReserve)

OptScheduler(
    res,
    interval,
    win,
    es::Float64,
    powerLimitPu,
    minNetLoadKw,
    regulationReserve,
) = OptScheduler(
    res,
    interval,
    win,
    (es, es),
    powerLimitPu,
    minNetLoadKw,
    regulationReserve,
)

function schedule(
    ess,
    scheduler::OptScheduler,
    useCases::AbstractVector{<:UseCase},
    tStart::Dates.DateTime,
    ::Progress,
)
    @debug "Scheduling with OptScheduler" scheduler maxlog = 1
    K = scheduler.optWindow
    scheduleLength =
        Int(ceil(scheduler.interval, scheduler.resolution) / scheduler.resolution)
    eta = sqrt(ηRT(ess))
    resolutionHrs = /(promote(scheduler.resolution, Hour(1))...)

    m = Model(HiGHS.Optimizer)
    set_optimizer_attribute(m, "presolve", "on")
    set_silent(m)

    @variables(m, begin
        e_min(ess) ≤ eng[1:K+1] ≤ e_max(ess) # energy state
        0 ≤ p_p[1:K] ≤ p_max(ess) * scheduler.powerLimitPu  # discharging power
        0 ≤ p_n[1:K] ≤ -p_min(ess) * scheduler.powerLimitPu  # charging power
        pBatt[1:K]   # power output of the battery
        pOut[1:K]    # net power output to the grid
        r_p[1:K] ≥ 0  # regulation-up power
        r_n[1:K] ≥ 0   # regulation-down power
        r_c[1:K] ≥ 0  # regulation power
        spn[1:K] ≥ 0  # spinning reserve
        con[1:K]   # T&D deferral for contingency events
        pvp[1:K] ≥ 0  # PV power output
    end)

    # Build expression of power output to grid
    pOutExp = mapreduce(
        uc -> power_output(scheduler, uc, tStart),
        .+,
        useCases;
        init = pBatt .+ pvp,
    )

    @constraints(
        m,
        begin
            eng[1] == energy_state(ess)
            pBatt .== p_p .- p_n
            pOut .== pOutExp
            # regulation up
            r_p .<= p_max(ess) .- pBatt
            r_p .+ spn .≤ p_max(ess) .- pBatt
            eng[1:end-1] .-
            (scheduler.regulationReserve .* r_p .+ spn) ./ eta .* resolutionHrs .≥
            e_min(ess)
            # regulation down
            r_n .<= -p_min(ess) .+ pBatt
            eng[1:end-1] .+ (scheduler.regulationReserve .* r_n .* eta) .* resolutionHrs .<=
            e_max(ess)
            # regulation
            # energy state dynamics
            eng[2:end] .==
            eng[1:end-1] .-
            (p_p ./ eta .- p_n .* eta .+ self_discharge_rate(ess) .* e_max(ess)) .*
            resolutionHrs
            # TODO: PV generation dump
            pvp .== 0
        end
    )

    if isnothing(scheduler.endSoc)
        @constraint(m, engy_final_condition, eng[end] == eng[1])
    else
        @constraints(
            m,
            begin
                eng[end] - e_min(ess) ≥ scheduler.endSoc[1] * (e_max(ess) - e_min(ess))
                eng[end] - e_min(ess) ≤ scheduler.endSoc[2] * (e_max(ess) - e_min(ess))
            end
        )
    end

    # Minimum net load power
    if !isnothing(scheduler.minNetLoadKw)
        @constraint(m, pOut .≤ -scheduler.minNetLoadKw)
    end

    # TODO: T&D upgrade deferral
    # if !isnothing(minDeferralPower)  # T&D deferral contingency event
    #     @constraint(m, pBatt .>= minDeferralPower)
    #     CON_Hours = findall(minDeferralPower .> 0)
    #     @constraint(m, con .== p_p .* (minDeferralPower .> 0))
    #     @constraint(m, r_p[CON_Hours] .== 0)
    #     @constraint(m, r_n[CON_Hours] .== 0)
    #     @constraint(m, spn[CON_Hours] .== 0)
    # else
    @constraint(m, con .== 0)
    # end

    # if ~UOBS_regulation_flag
    #     @constraint(m, r_p .== 0)
    #     @constraint(m, r_n .== 0)
    # end

    # if ~UOBS_spin_reserve_flag
    #     @constraint(m, spn .== 0)
    # end

    # Add use-case-specific variables and constraints, and
    # build objective function expression (to be maximized)
    objective_exp = mapreduce(uc -> var_con_obj!(m, uc, scheduler, tStart), +, useCases)
    @objective(m, Max, objective_exp)

    optimize!(m)
    sol_p_p = JuMP.value.(p_p)
    sol_p_n = JuMP.value.(p_n)
    sol_r_p = JuMP.value.(r_p)
    sol_r_n = JuMP.value.(r_n)
    sol_r_c = JuMP.value.(r_c)
    sol_pBatt = JuMP.value.(pBatt)
    sol_eng = JuMP.value.(eng)
    sol_spn = JuMP.value.(spn)
    sol_con = JuMP.value.(con)
    sol_pvp = JuMP.value.(pvp)
    if K < scheduleLength
        append!(sol_pBatt, zeros(scheduleLength - K))
    end

    currentSchedule = Schedule(
        sol_pBatt[1:scheduleLength],
        tStart;
        resolution = scheduler.resolution,
        SOC = (sol_eng[1:scheduleLength+1] .- e_min(ess)) ./ (e_max(ess) - e_min(ess)),
        regCapKw = sol_r_c[1:scheduleLength],
    )
    @debug "Schedule updated" currentSchedule
    return currentSchedule
end

var_con_obj!(::JuMP.Model, ::UseCase, ::OptScheduler, ::Dates.DateTime) = 0

power_output(::OptScheduler, ::UseCase, ::Dates.DateTime) = 0

# Energy Arbitrage

var_con_obj!(
    m::JuMP.Model,
    ucEA::EnergyArbitrage,
    scheduler::OptScheduler,
    tStart::Dates.DateTime,
) = FixedIntervalTimeSeries(tStart, scheduler.resolution, m[:pBatt]) ⋅ forecast_price(ucEA)

# Regulation
function var_con_obj!(
    m::JuMP.Model,
    ucReg::Regulation,
    scheduler::OptScheduler,
    tStart::Dates.DateTime,
)
    @constraints(m, begin
        m[:r_c] .<= m[:r_p]
        m[:r_c] .<= m[:r_n]
    end)

    # regulation capacity and service performance
    regOp = FixedIntervalTimeSeries(
        tStart,
        scheduler.resolution,
        [RegulationOperationPoint(x, 0) for x in m[:r_c]],
    )
    regulation_income(regOp, ucReg)

    # TODO: regulation up and down
    # objective_exp = @expression(m,
    #     objective_exp
    #     + sum(DA_Reg_up_price[(i-1)+k] * r_p[k] * Reg_Perf for k = 1:K)
    #     + sum(DA_Reg_dn_price[(i-1)+k] * r_n[k] * Reg_Perf for k = 1:K)
    #     + sum(DA_Spn_reserve_price[(i-1)+k] * spn[k] for k = 1:K)
    # )
end

# Demand Charge Reduction

power_output(sh::OptScheduler, ucDCR::DemandChargeReduction, tStart::Dates.DateTime) =
    .-get_values(
        mean(
            ucDCR.loadForecastKw15min,
            range(tStart; length = sh.optWindow + 1, step = sh.resolution),
        ),
    )

function var_con_obj!(
    m::JuMP.Model,
    ucDCR::DemandChargeReduction,
    scheduler::OptScheduler,
    tStart::Dates.DateTime,
)
    p, r = demand_charge_periods_rates(
        ucDCR.rateStructure,
        FixedIntervalTimeSeries(tStart, scheduler.resolution, .-m[:pOut]),
    )
    @variable(m, pPeak[1:length(p)] ≥ 0)
    @constraint(m, [iMonth = 1:length(p)], pPeak[iMonth] .≥ p[iMonth][1])
    -sum(pPeak[iMonth] * r[iMonth][1] for iMonth = 1:length(p))
end
