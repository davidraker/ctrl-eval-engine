
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
                    :op_history => Dict(
                        :timestamps => progress.operation.t,
                        :SOC_pu => CtrlEvalEngine.column_data(progress.operation, :SOC),
                        :power_kW => CtrlEvalEngine.column_data(progress.operation, :powerKw),
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

    power_kw = float.(scheduleDict["power_kW"])
    soc_raw = float.(scheduleDict["SOC_pu"])
    soc_full = if length(soc_raw) == length(power_kw) + 1
        soc_raw
    elseif length(soc_raw) == length(power_kw)
        [SOC(ess), soc_raw...]
    else
        error(
            "SOC_pu length must be either length(power_kW) or length(power_kW)+1. " *
            "Got length(SOC_pu)=$(length(soc_raw)), length(power_kW)=$(length(power_kw))",
        )
    end

    return Schedule(
        power_kw,
        tStart;
        resolution = Second(floor(Int, 3600 * get(scheduleDict, "resolution_hr", 1))),
        SOC = soc_full,
        regCapKw = scheduleDict["regulation_cap_kW"],
    )
end

function CtrlEvalEngine.cleanup(sch::UserDefinedScheduler)
    close(sch.chOut)
    wait(sch.task)
end
