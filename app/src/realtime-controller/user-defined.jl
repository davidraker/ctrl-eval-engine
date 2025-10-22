
using JSON

struct UserDefinedRTController <: RTController
    chIn::Channel{String}
    chOut::Channel{String}
    task::Any
end

function UserDefinedRTController(config::Dict, ess, useCases::AbstractVector{<:UseCase})
    chIn = Channel{String}()
    chOut = Channel{String}()
    # simple websocket client
    task = @async WebSockets.open("ws://localhost:9500") do ws
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

    put!(
        chOut,
        JSON.json(
            Dict(
                :type => "initialize",
                :payload => Dict(config..., :ess => essParameters, :use_cases => useCases),
            ),
        ),
    )
    responseDict = JSON.parse(take!(chIn))
    if haskey(responseDict, "error") ||
        get(responseDict, "message", nothing) !== "Initialized"
        throw(
            CtrlEvalEngine.InitializationFailure(
                get(
                    responseDict,
                    "error",
                    "User-defined real-time controller failed to initialize",
                ),
            ),
        )
    end

    UserDefinedRTController(chIn, chOut, task)
end

function control(
    ess::EnergyStorageSystem,
    controller::UserDefinedRTController,
    schedulePeriod::TimeFrameRow,
    useCases::AbstractVector{<:UseCase},
    t::Dates.DateTime,
    spProgress::VariableIntervalTimeSeries,
)
    @debug "UserDefinedRTController" t

    put!(
        controller.chOut,
        JSON.json(
            Dict(
                :type => "compute",
                :payload => Dict(
                    :current_SOC_pu => SOC(ess),
                    :use_cases => useCases,
                    :t => t,
                    :schedule_period => schedulePeriod,
                    :schedule_period_progress => Dict(
                        :timestamps => timestamps(spProgress),
                        :power_kW => values(spProgress),
                    ),
                ),
            ),
        ),
    )
    controlSeqDict = JSON.parse(take!(controller.chIn))

    if haskey(controlSeqDict, "error")
        error(controlSeqDict["error"])
    end

    return FixedIntervalTimeSeries(
        tStart,
        Millisecond(floor(Int, 1000 * controlSeqDict["resolution_sec"])),
        float.(controlSeqDict["power_kW"]),
    )
end

function CtrlEvalEngine.cleanup(controller::UserDefinedRTController)
    close(controller.chOut)
    wait(controller.task)
end
