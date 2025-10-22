
using HTTP, HTTP.WebSockets, Sockets
using JSON

struct UserDefinedScheduler <: Scheduler
    chIn::Channel{String}
    chOut::Channel{String}
    task::Any
end

function UserDefinedScheduler(config::Dict, ess, useCases::AbstractVector{<:UseCase})
    chIn = Channel{String}()
    chOut = Channel{String}()
    # simple websocket client
    task = @async WebSockets.open("ws://localhost:9000") do ws
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
        "e_max_kWh" => e_max(ess),
        "e_min_kWh" => e_min(ess),
        "p_max_kW" => p_max(ess),
        "RTE_pu" => ηRT(ess),
    )

    initString = JSON.json(
        Dict(
            :type => "initialize",
            :payload => Dict(config..., :ess => essParameters, :use_cases => useCases),
        ),
    )
    @debug "Initializing UserDefinedScheduler" initString
    put!(chOut, initString)

    responseDict = JSON.parse(take!(chIn))

    if haskey(responseDict, "error") ||
       get(responseDict, "message", nothing) !== "Initialized"
        throw(
            CtrlEvalEngine.InitializationFailure(
                get(responseDict, "error", "User-defined scheduler failed to initialize"),
            ),
        )
    end

    UserDefinedScheduler(chIn, chOut, task)
end

function schedule(
    ess,
    sch::UserDefinedScheduler,
    useCases::AbstractVector{<:UseCase},
    tStart::Dates.DateTime,
    progress::Progress,
)
    put!(
        sch.chOut,
        JSON.json(
            Dict(
                :type => "compute",
                :payload => Dict(
                    :current_SOC_pu => SOC(ess),
                    :use_cases => useCases,
                    :t => tStart,
                    :history => Dict(
                        :timestamps => progress.operation.t,
                        :SOC_pu => progress.operation.SOC,
                        :power_kW => progress.operation.powerKw,
                    ),
                ),
            ),
        ),
    )
    scheduleDict = JSON.parse(take!(sch.chIn))

    @debug "UserDefinedScheduler" t = tStart scheduleDict

    if haskey(scheduleDict, "error")
        error(scheduleDict["error"])
    end

    return create_schedule(
        float.(scheduleDict["power_kW"]),
        tStart;
        resolution = Second(floor(Int, 3600 * get(scheduleDict, "resolution_hr", 1))),
        SOC = [SOC(ess), float.(scheduleDict["SOC_pu"])...],
        regCapKw = scheduleDict["regulation_cap_kW"],
    )
end

function CtrlEvalEngine.cleanup(sch::UserDefinedScheduler)
    close(sch.chOut)
    wait(sch.task)
end
