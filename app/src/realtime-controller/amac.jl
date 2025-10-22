
using JSON
using ..CtrlEvalEngine: start_time, end_time

struct AMAController <: RTController
    chIn::Channel{String}
    chOut::Channel{String}
    task::Any
    passive::Bool
end

function AMAController(
    controlConfig::Dict,
    ess::EnergyStorageSystem,
    useCases::AbstractArray{<:UseCase},
)
    chIn = Channel{String}()
    chOut = Channel{String}()
    task = nothing

    idxVM = findfirst(uc -> uc isa VariabilityMitigation, useCases)
    if !isnothing(idxVM)
        ucVM::VariabilityMitigation = useCases[idxVM]
        # TODO: update data interval based on input profile
        # pyAmac.set_data_interval(ucVM.pvGenProfile.resolution / Second(1))

        # simple websocket client
        task = @async WebSockets.open("ws://localhost:6500") do ws
            # we can iterate the websocket
            # where each iteration yields a received message
            # iteration finishes when the websocket is closed
            for msg in chOut
                # do stuff with msg
                send(ws, msg)
                put!(chIn, receive(ws))
            end
            close(chIn)
        end

        essParameters = Dict(
            :rated_kw => p_max(ess),
            :rated_kwh => e_max(ess) - e_min(ess),
            :eta => ηRT(ess),
            :soc_max => 100,
            :soc_min => e_min(ess) / e_max(ess) * 100,
        )

        put!(
            chOut,
            JSON.json(
                Dict(
                    :type => "initialize",
                    :payload => Dict(
                        controlConfig...,
                        :ess => essParameters,
                        :maximum_pv_power => ucVM.ratedPowerKw,
                    ),
                ),
            ),
        )
        responseDict = JSON.parse(take!(chIn))
        if haskey(responseDict, "error") ||
           get(responseDict, "message", nothing) !== "Initialized"
            throw(CtrlEvalEngine.InitializationFailure("AMAC failed to initialize"))
        end
    end

    # If VariabilityMitigation use case isn't selected, fall back to passive control according to schedule
    AMAController(chIn, chOut, task, isnothing(idxVM))
end

function control(
    ess,
    amac::AMAController,
    sp::TimeFrameRow,
    useCases::AbstractArray{<:UseCase},
    t::DateTime,
    ::VariableIntervalTimeSeries,
)
    if amac.passive
        # Fall back to passive control according to schedule
        return FixedIntervalTimeSeries(t, sp.duration, [sp.powerKw])
    end

    idxVM = findfirst(uc -> uc isa VariabilityMitigation, useCases)
    ucVM::VariabilityMitigation = useCases[idxVM]
    if start_time(ucVM.pvGenProfile) > t
        # Passive control until start of PV generation or end of SchedulePeriod, whichever comes first
        return FixedIntervalTimeSeries(
            t,
            min(start_time(ucVM.pvGenProfile), end_time(sp)) - t,
            [sp.powerKw],
        )
    end

    if t ≥ end_time(ucVM.pvGenProfile)
        # Passive control to the end of SchedulePeriod if PV generation profile has ended
        return FixedIntervalTimeSeries(t, end_time(sp) - t, [sp.powerKw])
    end

    # Active control if PV generation is present
    currentPvGen, _, tEndPvGenPeriod = get_period(ucVM.pvGenProfile, t)
    controlDuration = tEndPvGenPeriod - t

    put!(
        amac.chOut,
        JSON.json(
            Dict(
                :pvGen => currentPvGen,
                :socPct => SOC(ess) * 100,
                :refSocPct => sp.socEnd * 100,
                :t => t,
            ),
        ),
    )
    controlSeqDict = JSON.parse(take!(amac.chIn))
    battery_power = min(
        max(p_min(ess, controlDuration), controlSeqDict["battery_power"] + sp.powerKw),
        p_max(ess, controlDuration),
    )
    @debug "Active AMAC" t controlDuration maxlog = 20
    return FixedIntervalTimeSeries(t, controlDuration, [battery_power])
end

function CtrlEvalEngine.cleanup(amac::AMAController)
    close(amac.chOut)
    if amac.task !== nothing
        wait(amac.task)
    end
end
