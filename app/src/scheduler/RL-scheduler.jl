
using HTTP, HTTP.WebSockets, Sockets

struct RLScheduler <: Scheduler
    resolution::Dates.Period
    chIn::Channel{String}
    chOut::Channel{String}
    task::Any
end

function RLScheduler(res::Dates.Period, config::AbstractDict, ess::EnergyStorageSystem)
    chIn = Channel{String}()
    chOut = Channel{String}()
    # simple websocket client
    task = @async WebSockets.open("ws://localhost:6000") do ws
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
        "energy" => e_max(ess),
        "power" => p_max(ess),
        "efficiency" => ηRT(ess),
        "soc_low" => e_min(ess) / e_max(ess),
        "soc_high" => 1,
    )

    put!(
        chOut,
        JSON.json(
            Dict(
                :type => "initialize",
                :payload => Dict(
                    config...,
                    :essParameters => essParameters,
                    :resolution_hrs => res / Hour(1),
                ),
            ),
        ),
    )
    responseDict = JSON.parse(take!(chIn))
    if haskey(responseDict, "error") ||
       get(responseDict, "message", nothing) !== "Initialized"
        throw(CtrlEvalEngine.InitializationFailure(get(responseDict, "error", "RL scheduler failed to initialize")))
    end

    RLScheduler(res, chIn, chOut, task)
end

function schedule(
    ess,
    rlScheduler::RLScheduler,
    useCases::AbstractVector{<:UseCase},
    tStart::Dates.DateTime,
    ::Progress,
)
    eaIdx = findfirst(uc -> uc isa EnergyArbitrage, useCases)
    if isnothing(eaIdx)
        error("No supported use case is found by ML scheduler")
    end
    ucEA = useCases[eaIdx]

    price = sample(
        forecast_price(ucEA),
        range(
            tStart;
            step = rlScheduler.resolution,
            stop = tStart + Hour(24) - Millisecond(1),
        ),
    )
    @debug "RL-scheduler" t = tStart resolution = rlScheduler.resolution price
    put!(rlScheduler.chOut, JSON.json(Dict(:price => price, :initial_soc => SOC(ess))))
    scheduleDict = JSON.parse(take!(rlScheduler.chIn))
    return create_schedule(
        float.(scheduleDict["powerKw"]),
        tStart;
        resolution = rlScheduler.resolution,
        SOC = [SOC(ess), float.(scheduleDict["soc"])...],
    )
end

function CtrlEvalEngine.cleanup(rlScheduler::RLScheduler)
    close(rlScheduler.chOut)
    wait(rlScheduler.task)
end