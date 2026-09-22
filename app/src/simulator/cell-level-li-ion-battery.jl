using HTTP, HTTP.WebSockets, Sockets
using JSON

const BMS_CONTROL_PORT = 7000
const BMS_CONNECTION_ATTEMPTS = 30

struct CellPackRatings
    ns::Int
    np::Int
    nm::Int
    q_cell_ah::Float64
    v_cell_nom::Float64
    c_max::Float64
    soc_min::Float64
    soc_max::Float64
    e_full_kwh::Float64
    p_rated_kw::Float64
end

mutable struct CellLevelLiIonBattery <: EnergyStorageSystem
    ratings::CellPackRatings
    eta_rt::Float64
    chIn::Channel{String}
    chOut::Channel{String}
    task::Any
    state::Dict{String,Any}
    bmsRecords::Vector{Dict{String,Any}}
    bmsSummary::Dict{String,Any}
    bmsConfig::Dict{String,Any}
    bmsRecordFields::Vector{String}
end

function cell_pack_energy_kwh(ns, np, nm, q_cell_ah, v_cell_nom)
    float(ns) * float(np) * float(nm) * float(q_cell_ah) * float(v_cell_nom) / 1000
end

function _cell_number(dict, key, fallback)
    value = dict isa Dict ? get(dict, key, fallback) : fallback
    return value isa Real ? float(value) : float(fallback)
end

function cell_pack_ratings(cellSimulation::Dict, bmsController=nothing)
    ns = max(1, round(Int, _cell_number(cellSimulation, "ns", 1)))
    np = max(1, round(Int, _cell_number(cellSimulation, "np", 1)))
    nm = max(1, round(Int, _cell_number(cellSimulation, "nm", 1)))
    q_cell_ah = _cell_number(cellSimulation, "q_cell_ah", 50.0)
    v_cell_nom = _cell_number(cellSimulation, "v_cell_nom", 3.7)
    c_max = _cell_number(cellSimulation, "C_max", 1.0)
    constraints =
        bmsController isa Dict ? get(bmsController, "constraints", Dict()) : Dict()
    soc_min = _cell_number(constraints, "soc_min", 0.0)
    soc_max = _cell_number(constraints, "soc_max", 1.0)
    e_full = cell_pack_energy_kwh(ns, np, nm, q_cell_ah, v_cell_nom)
    CellPackRatings(ns, np, nm, q_cell_ah, v_cell_nom, c_max, soc_min, soc_max, e_full, c_max * e_full)
end

const _BMS_STATE_KEYS = (
    "powerKw",
    "SOC",
    "SOH",
    "etaRt",
    "cellVMin",
    "cellVMax",
    "cellVAvg",
    "cellSocMin",
    "cellSocMax",
    "cellSocAvg",
    "cellSocStd",
    "cellTempMin",
    "cellTempMax",
    "cellTempAvg",
    "cellBalancingEnergyWh",
    "cellCapacityFadeAvg",
    "cellResistanceGrowthAvg",
)

function _merge_bms_state!(state::Dict, responseDict)
    for key in _BMS_STATE_KEYS
        if haskey(responseDict, key)
            state[key] = responseDict[key]
        end
    end
    return state
end

function _bms_nested(responseDict, key, fallback)
    if haskey(responseDict, key)
        return responseDict[key]
    end
    state = get(responseDict, "state", nothing)
    if state isa Dict && haskey(state, key)
        return state[key]
    end
    return fallback
end

function bms_compute_payload(powerKw, durationHour, temperatureDegreeC)
    Dict(
        :type => "compute",
        :payload => Dict(
            :power_kw => powerKw,
            :duration_s => durationHour * 3600,
            :ambient_temp_c => temperatureDegreeC,
        ),
    )
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

function _bms_initial_state()
    Dict{String,Any}(
        "powerKw" => 0.0,
        "SOC" => 0.5,
        "SOH" => 1.0,
    )
end

function CellLevelLiIonBattery(
    batteryType::AbstractString,
    cellSimulation::Dict,
    bmsController,
)
    chIn = Channel{String}(1)
    chOut = Channel{String}(1)
    task = _start_bms_connection(chIn, chOut)

    ratings = cell_pack_ratings(cellSimulation, bmsController)
    initPayload = Dict(
        :type => "initialize",
        :payload => Dict(
            :type => "bms",
            :selectedBatteryCharacteristics => Dict("batteryType" => batteryType),
            :cellSimulation => cellSimulation,
            :bmsController => bmsController === nothing ? Dict() : bmsController,
            :ess => Dict(
                :initial_SOC_pu => 0.5,
                :initial_SOH_pu => 1.0,
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

    state = _bms_initial_state()
    if get(responseDict, "state", nothing) isa Dict
        _merge_bms_state!(state, responseDict["state"])
    end
    _merge_bms_state!(state, responseDict)

    bmsSummary = _bms_nested(responseDict, "bmsSummary", Dict{String,Any}())
    bmsConfig = _bms_nested(responseDict, "bmsConfig", Dict{String,Any}())
    bmsRecordFields = _bms_nested(responseDict, "bmsRecordFields", String[])
    etaRt = _bms_nested(responseDict, "etaRt", 1.0)
    etaRt = etaRt isa Real ? float(etaRt) : 1.0

    return CellLevelLiIonBattery(
        ratings,
        etaRt,
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

ηRT(ess::CellLevelLiIonBattery) = ess.eta_rt
self_discharge_rate(::CellLevelLiIonBattery) = 0.0
SOC(ess::CellLevelLiIonBattery) = _bms_state_float(ess, "SOC", 0.5)
SOH(ess::CellLevelLiIonBattery) = _bms_state_float(ess, "SOH", 1.0)
energy_state(ess::CellLevelLiIonBattery) = SOC(ess) * e_max(ess)
e_max(ess::CellLevelLiIonBattery) = ess.ratings.e_full_kwh
e_min(::CellLevelLiIonBattery) = 0.0
p_max(ess::CellLevelLiIonBattery) = ess.ratings.p_rated_kw
p_min(ess::CellLevelLiIonBattery) = -ess.ratings.p_rated_kw

function _duration_discharge_kw(ess::CellLevelLiIonBattery, durationHour::Real)
    durationHour = float(durationHour)
    if durationHour <= 0
        return p_max(ess)
    end
    headroom = max(SOC(ess) - ess.ratings.soc_min, 0.0) * e_max(ess) / durationHour
    return min(p_max(ess), headroom)
end

function _duration_charge_kw(ess::CellLevelLiIonBattery, durationHour::Real)
    durationHour = float(durationHour)
    if durationHour <= 0
        return p_min(ess)
    end
    headroom = max(ess.ratings.soc_max - SOC(ess), 0.0) * e_max(ess) / durationHour
    return max(p_min(ess), -headroom)
end

p_max(ess::CellLevelLiIonBattery, durationHour::Real, ::Real) =
    _duration_discharge_kw(ess, durationHour)
p_min(ess::CellLevelLiIonBattery, durationHour::Real, ::Real) =
    _duration_charge_kw(ess, durationHour)

function _operate!(
    ess::CellLevelLiIonBattery,
    powerKw::Real,
    durationHour::Real,
    temperatureDegreeC::Real,
)
    put!(ess.chOut, JSON.json(bms_compute_payload(powerKw, durationHour, temperatureDegreeC)))
    responseDict = JSON.parse(take!(ess.chIn); dicttype = Dict)
    if haskey(responseDict, "error")
        error(responseDict["error"])
    end

    _merge_bms_state!(ess.state, responseDict)
    if haskey(responseDict, "etaRt") && responseDict["etaRt"] isa Real
        ess.eta_rt = float(responseDict["etaRt"])
    end
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
            :yAxisRight => Dict(:title => "Module current (A)"),
            :data => [
                Dict(
                    :x => x,
                    :y => _bms_series(records, "pack_power_kw"; scale = float(ess.ratings.nm)),
                    :type => "instance",
                    :name => "Plant Power",
                ),
                Dict(
                    :x => x,
                    :y => _bms_series(records, "pack_current"),
                    :type => "instance",
                    :name => "Module Current",
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
