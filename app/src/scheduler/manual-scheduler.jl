struct ManualScheduler <: Scheduler
    powerKw::Vector{Float64}
    tStart::Dates.DateTime
    resolution::Dates.Period
end

"""
    schedule(ess, scheduler, useCases, tStart)

Schedule the operation of `ess` with `scheduler` given `useCases` starting from `tStart`
"""
function schedule(ess, scheduler::ManualScheduler, _, tStart::Dates.DateTime, ::Progress)
    currentSchedule = Schedule(
        max.(
            min.(scheduler.powerKw, p_max(ess, scheduler.resolution)),
            p_min(ess, scheduler.resolution),
        ),
        tStart;
        resolution = Second(scheduler.resolution),
        SOC = fill(SOC(ess), length(scheduler.powerKw) + 1),
    )
    return currentSchedule
end
