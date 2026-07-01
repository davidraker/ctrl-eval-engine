using HTTP, HTTP.WebSockets, Sockets
using JSON

const BMS_CONTROL_PORT = 7000
const BMS_CONNECTION_ATTEMPTS = 30

mutable struct CellLevelLiIonBattery <: EnergyStorageSystem
    base::LiIonBattery
    chIn::Channel{String}
    chOut::Channel{String}
    task::Any
    state::Dict{String,Any}
    bmsRecords::Vector{Dict{String,Any}}
    bmsSummary::Dict{String,Any}
    bmsConfig::Dict{String,Any}
    bmsRecordFields::Vector{String}
end

function _start_bms_connection(chIn::Channel{String}, chOut::Channel{String})
    @async begin
        for attempt in 1:BMS_CONNECTION_ATTEMPTS
            try
                WebSockets.open("ws://localhost:$BMS_CONTROL_PORT") do ws
                    for msg in chOut
                        send(ws, msg)
                        put!(chIn, receive(ws))
                    end
                    close(chIn)
                end
                return
            catch e
                if !isopen(chOut)
                    close(chIn)
                    return
                end
                if attempt == BMS_CONNECTION_ATTEMPTS
                    put!(
                        chIn,
                        JSON.json(
                            Dict(
                                "error" => "Unable to connect to BMS controller on localhost:$BMS_CONTROL_PORT",
                                "details" => sprint(showerror, e),
                            ),
                        ),
                    )
                    close(chIn)
                    return
                end
                sleep(1)
            end
        end
    end
end

function _bms_state_float(
    ess::CellLevelLiIonBattery,
    key::String,
    fallback::Real,
)
    value = get(ess.state, key, fallback)
    return value isa Real ? float(value) : float(fallback)
end

function _bms_initial_state(base::LiIonBattery)
    Dict{String,Any}(
        "powerKw" => 0.0,
        "SOC" => SOC(base),
        "SOH" => SOH(base),
    )
end

function CellLevelLiIonBattery(
    base::LiIonBattery,
    batteryConfig::Dict,
    cellSimulation::Dict,
    bmsController,
)
    chIn = Channel{String}(1)
    chOut = Channel{String}(1)
    task = _start_bms_connection(chIn, chOut)

    initPayload = Dict(
        :type => "initialize",
        :payload => Dict(
            :type => "bms",
            :selectedBatteryCharacteristics => batteryConfig,
            :cellSimulation => cellSimulation,
            :bmsController => bmsController === nothing ? Dict() : bmsController,
            :ess => Dict(
                :e_max_kWh => e_max(base),
                :e_min_kWh => e_min(base),
                :p_max_kW => p_max(base),
                :RTE_pu => ηRT(base),
                :initial_SOC_pu => SOC(base),
                :initial_SOH_pu => SOH(base),
            ),
        ),
    )

    put!(chOut, JSON.json(initPayload))
    responseDict = JSON.parse(take!(chIn); dicttype = Dict)
    if haskey(responseDict, "error") ||
       get(responseDict, "message", nothing) != "Initialized"
        throw(
            CtrlEvalEngine.InitializationFailure(
                get(responseDict, "error", "BMS controller failed to initialize"),
            ),
        )
    end

    state = _bms_initial_state(base)
    if get(responseDict, "state", nothing) isa Dict
        merge!(state, responseDict["state"])
    end

    bmsSummary = get(responseDict, "bmsSummary", Dict{String,Any}())
    bmsConfig = get(responseDict, "bmsConfig", Dict{String,Any}())
    bmsRecordFields = get(responseDict, "bmsRecordFields", String[])

    return CellLevelLiIonBattery(
        base,
        chIn,
        chOut,
        task,
        state,
        Dict{String,Any}[],
        bmsSummary isa Dict ? bmsSummary : Dict{String,Any}(),
        bmsConfig isa Dict ? bmsConfig : Dict{String,Any}(),
        bmsRecordFields isa Vector ? string.(bmsRecordFields) : String[],
    )
end

ηRT(ess::CellLevelLiIonBattery) = ηRT(ess.base)
self_discharge_rate(ess::CellLevelLiIonBattery) = self_discharge_rate(ess.base)
SOC(ess::CellLevelLiIonBattery) = _bms_state_float(ess, "SOC", SOC(ess.base))
SOH(ess::CellLevelLiIonBattery) = _bms_state_float(ess, "SOH", SOH(ess.base))
energy_state(ess::CellLevelLiIonBattery) = SOC(ess) * e_max(ess)
e_max(ess::CellLevelLiIonBattery) = e_max(ess.base)
e_min(ess::CellLevelLiIonBattery) = e_min(ess.base)
p_max(ess::CellLevelLiIonBattery) = p_max(ess.base)
p_min(ess::CellLevelLiIonBattery) = p_min(ess.base)

p_max(
    ess::CellLevelLiIonBattery,
    durationHour::Real,
    ambientTemperatureDegreeC::Real,
) = p_max(ess.base)

p_min(
    ess::CellLevelLiIonBattery,
    durationHour::Real,
    ambientTemperatureDegreeC::Real,
) = p_min(ess.base)

function _operate!(
    ess::CellLevelLiIonBattery,
    powerKw::Real,
    durationHour::Real,
    temperatureDegreeC::Real,
)
    put!(
        ess.chOut,
        JSON.json(
            Dict(
                :type => "compute",
                :payload => Dict(
                    :power_kw => powerKw,
                    :duration_s => durationHour * 3600,
                    :ambient_temp_c => temperatureDegreeC,
                ),
            ),
        ),
    )
    responseDict = JSON.parse(take!(ess.chIn); dicttype = Dict)
    if haskey(responseDict, "error")
        error(responseDict["error"])
    end

    merge!(ess.state, responseDict)
    bmsRecords = get(responseDict, "bmsRecords", nothing)
    if bmsRecords isa Vector
        for record in bmsRecords
            if record isa Dict
                push!(ess.bmsRecords, copy(record))
            end
        end
    elseif get(responseDict, "bmsRecord", nothing) isa Dict
        push!(ess.bmsRecords, copy(responseDict["bmsRecord"]))
    end

    if get(responseDict, "bmsSummary", nothing) isa Dict
        ess.bmsSummary = copy(responseDict["bmsSummary"])
    end
    if get(responseDict, "bmsConfig", nothing) isa Dict
        ess.bmsConfig = copy(responseDict["bmsConfig"])
    end
    if get(responseDict, "bmsRecordFields", nothing) isa Vector
        ess.bmsRecordFields = string.(responseDict["bmsRecordFields"])
    end

    return (;
        powerKw = _bms_state_float(ess, "powerKw", powerKw),
        SOC = SOC(ess),
        SOH = SOH(ess),
    )
end

initialize_extra_operations(ess::CellLevelLiIonBattery) = (
    [PointSeries([SOH(ess)])],
    [:SOH],
)

function CtrlEvalEngine.cleanup(ess::CellLevelLiIonBattery)
    close(ess.chOut)
    wait(ess.task)
end

function _bms_elapsed_seconds(record::Dict{String,Any})
    value = get(record, "time", 0.0)
    if value isa Real
        return Float64(value)
    end
    try
        return parse(Float64, string(value))
    catch
        return 0.0
    end
end

function _bms_timestamp(startTimestamp::Dates.DateTime, record::Dict{String,Any})
    elapsedMs = round(Int, _bms_elapsed_seconds(record) * 1000.0)
    return string(startTimestamp + Dates.Millisecond(elapsedMs))
end

function _bms_records_with_timestamps(
    ess::CellLevelLiIonBattery,
    operation::TimeFrame,
)
    startTimestamp = operation.t[1]
    records = Dict{String,Any}[]
    for record in ess.bmsRecords
        stampedRecord = copy(record)
        stampedRecord["timestamp"] = _bms_timestamp(startTimestamp, record)
        push!(records, stampedRecord)
    end
    return records
end

function bms_output(ess::CellLevelLiIonBattery, operation::TimeFrame)
    return Dict(
        :records => _bms_records_with_timestamps(ess, operation),
        :summary => ess.bmsSummary,
        :config => ess.bmsConfig,
        :recordFields => ess.bmsRecordFields,
    )
end

function _bms_series(records, field::String; scale = 1.0, default = 0.0)
    map(records) do record
        value = get(record, field, default)
        value isa Real ? Float64(value) * scale : default
    end
end

function _bms_has_field(records, field::String)
    any(record -> haskey(record, field), records)
end

function bms_chart_data(ess::CellLevelLiIonBattery, operation::TimeFrame)
    records = _bms_records_with_timestamps(ess, operation)
    if isempty(records)
        return Any[]
    end

    x = [record["timestamp"] for record in records]
    charts = Any[
        Dict(
            :title => "BMS Pack Operation",
            :height => "400px",
            :xAxis => Dict(:title => "Time"),
            :yAxisLeft => Dict(:title => "Power (kW)"),
            :yAxisRight => Dict(:title => "Current (A)"),
            :data => [
                Dict(
                    :x => x,
                    :y => _bms_series(records, "pack_power_kw"),
                    :type => "instance",
                    :name => "Pack Power",
                ),
                Dict(
                    :x => x,
                    :y => _bms_series(records, "pack_current"),
                    :type => "instance",
                    :name => "Pack Current",
                    :yAxis => "right",
                ),
            ],
        ),
        Dict(
            :title => "BMS Cell SOC",
            :height => "400px",
            :xAxis => Dict(:title => "Time"),
            :yAxisLeft => Dict(:title => "SOC", :tickformat => ",.0%"),
            :data => [
                Dict(:x => x, :y => _bms_series(records, "soc_avg"), :type => "instance", :name => "SOC Avg"),
                Dict(:x => x, :y => _bms_series(records, "soc_min"), :type => "instance", :name => "SOC Min"),
                Dict(:x => x, :y => _bms_series(records, "soc_max"), :type => "instance", :name => "SOC Max"),
            ],
        ),
        Dict(
            :title => "BMS Pack Voltage",
            :height => "400px",
            :xAxis => Dict(:title => "Time"),
            :yAxisLeft => Dict(:title => "Voltage (V)"),
            :data => [
                Dict(:x => x, :y => _bms_series(records, "pack_voltage"), :type => "instance", :name => "Pack Voltage"),
            ],
        ),
        Dict(
            :title => "BMS Temperature and Balancing",
            :height => "400px",
            :xAxis => Dict(:title => "Time"),
            :yAxisLeft => Dict(:title => "Temperature (C)"),
            :yAxisRight => Dict(:title => "Cells Balancing"),
            :data => [
                Dict(:x => x, :y => _bms_series(records, "temp_avg"), :type => "instance", :name => "Temperature Avg"),
                Dict(:x => x, :y => _bms_series(records, "temp_min"), :type => "instance", :name => "Temperature Min"),
                Dict(:x => x, :y => _bms_series(records, "temp_max"), :type => "instance", :name => "Temperature Max"),
                Dict(
                    :x => x,
                    :y => _bms_series(records, "n_cells_balancing"),
                    :type => "instance",
                    :name => "Cells Balancing",
                    :yAxis => "right",
                ),
            ],
        ),
    ]

    if _bms_has_field(records, "cap_fade_avg")
        push!(
            charts,
            Dict(
                :title => "BMS Capacity Fade",
                :height => "400px",
                :xAxis => Dict(:title => "Time"),
                :yAxisLeft => Dict(:title => "Capacity Fade", :tickformat => ",.2%"),
                :data => [
                    Dict(:x => x, :y => _bms_series(records, "cap_fade_avg"), :type => "instance", :name => "Total Avg"),
                    Dict(:x => x, :y => _bms_series(records, "cal_fade_avg"), :type => "instance", :name => "Calendar Avg"),
                    Dict(:x => x, :y => _bms_series(records, "cyc_fade_avg"), :type => "instance", :name => "Cycle Avg"),
                    Dict(:x => x, :y => _bms_series(records, "cap_fade_spread"), :type => "instance", :name => "Cell Spread"),
                ],
            ),
            Dict(
                :title => "BMS State of Health",
                :height => "400px",
                :xAxis => Dict(:title => "Time"),
                :yAxisLeft => Dict(:title => "SOH", :tickformat => ",.0%"),
                :data => [
                    Dict(:x => x, :y => _bms_series(records, "soh_avg"; scale = 0.01), :type => "instance", :name => "SOH Avg"),
                    Dict(:x => x, :y => _bms_series(records, "soh_min"; scale = 0.01), :type => "instance", :name => "SOH Min"),
                ],
            ),
            Dict(
                :title => "BMS Resistance Growth",
                :height => "400px",
                :xAxis => Dict(:title => "Time"),
                :yAxisLeft => Dict(:title => "Resistance Growth", :tickformat => ",.2%"),
                :data => [
                    Dict(:x => x, :y => _bms_series(records, "res_growth_avg"), :type => "instance", :name => "Total Avg"),
                    Dict(:x => x, :y => _bms_series(records, "cal_res_growth_avg"), :type => "instance", :name => "Calendar Avg"),
                    Dict(:x => x, :y => _bms_series(records, "cyc_res_growth_avg"), :type => "instance", :name => "Cycle Avg"),
                    Dict(:x => x, :y => _bms_series(records, "res_growth_spread"), :type => "instance", :name => "Cell Spread"),
                ],
            ),
        )
    end

    return charts
end
