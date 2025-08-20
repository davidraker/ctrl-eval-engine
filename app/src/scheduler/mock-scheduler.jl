
struct MockScheduler <: Scheduler
    resolution::Dates.Period
    interval::Dates.Period
    sleepSeconds::Float64
end

"""
    schedule(ess, scheduler, useCases, tStart)

Schedule the operation of `ess` with `scheduler` given `useCases` starting from `tStart`
"""
function schedule(ess, scheduler::MockScheduler, _, tStart::Dates.DateTime, ::Progress)
    scheduleLength =
        Int(ceil(scheduler.interval, scheduler.resolution) / scheduler.resolution)
    currentSchedule = Schedule(
        rand(scheduleLength) .*
        (p_max(ess, scheduler.interval) - p_min(ess, scheduler.interval)) .+
        p_min(ess, scheduler.interval),
        tStart;
        resolution = scheduler.resolution,
        SOC = fill(SOC(ess), scheduleLength + 1),
    )

    sleep(scheduler.sleepSeconds)
    @debug "Schedule updated" currentSchedule
    return currentSchedule
end