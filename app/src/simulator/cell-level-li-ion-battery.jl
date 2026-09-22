using HTTP, HTTP.WebSockets, Sockets
using JSON

const BMS_CONTROL_PORT = 7000
const BMS_CONNECTION_ATTEMPTS = 30

struct CellModuleRatings
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

mutable struct CellLevelStates
    powerKw::Float64
    SOC::Float64
    SOH::Float64
    eta_rt::Float64
end

struct CellStep
    elapsedS::Float64
    powerKw::Float64
    SOC::Float64
    SOH::Float64
    cellSocMin::Float64
    cellSocMax::Float64
    cellVMin::Float64
    cellVMax::Float64
    cellVAvg::Float64
    moduleVoltage::Float64
    tempMin::Float64
    tempMax::Float64
    tempAvg::Float64
    moduleCurrentA::Float64
    nCellsBalancing::Float64
    capFadeAvg::Float64
    calFadeAvg::Float64
    cycFadeAvg::Float64
    capFadeSpread::Float64
    sohMin::Float64
    resGrowthAvg::Float64
    calResGrowthAvg::Float64
    cycResGrowthAvg::Float64
    resGrowthSpread::Float64
end

struct CellLevelResult
    powerKw::Float64
    SOC::Float64
    SOH::Float64
    steps::Vector{CellStep}
end

struct CellLevelLiIonBattery <: EnergyStorageSystem
    ratings::CellModuleRatings
    states::CellLevelStates
    chIn::Channel{String}
    chOut::Channel{String}
    task::Any
end

const CELL_POINT_HEADERS = (
    :SOH,
    :cellSocMin,
    :cellSocMax,
    :cellVMin,
    :cellVMax,
    :cellVAvg,
    :moduleVoltage,
    :tempMin,
    :tempMax,
    :tempAvg,
    :capFadeAvg,
    :calFadeAvg,
    :cycFadeAvg,
    :capFadeSpread,
    :sohMin,
    :resGrowthAvg,
    :calResGrowthAvg,
    :cycResGrowthAvg,
    :resGrowthSpread,
)

const CELL_PERIOD_HEADERS = (:moduleCurrentA, :nCellsBalancing)

function module_energy_kwh(ns, np, nm, q_cell_ah, v_cell_nom)
    float(ns) * float(np) * float(nm) * float(q_cell_ah) * float(v_cell_nom) / 1000
end

function _cell_number(dict, key, fallback)
    value = dict isa Dict ? get(dict, key, fallback) : fallback
    return value isa Real ? float(value) : float(fallback)
end

function module_ratings(cellSimulation::Dict, bmsController=nothing)
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
    e_full = module_energy_kwh(ns, np, nm, q_cell_ah, v_cell_nom)
    CellModuleRatings(
        ns,
        np,
        nm,
        q_cell_ah,
        v_cell_nom,
        c_max,
        soc_min,
        soc_max,
        e_full,
        c_max * e_full,
    )
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

function _record_float(record, key, fallback = 0.0)
    value = get(record, key, fallback)
    return value isa Real ? float(value) : float(fallback)
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

function operation_point(step::CellStep)
    (
        powerKw = step.powerKw,
        SOC = step.SOC,
        SOH = step.SOH,
        cellSocMin = step.cellSocMin,
        cellSocMax = step.cellSocMax,
        cellVMin = step.cellVMin,
        cellVMax = step.cellVMax,
        cellVAvg = step.cellVAvg,
        moduleVoltage = step.moduleVoltage,
        tempMin = step.tempMin,
        tempMax = step.tempMax,
        tempAvg = step.tempAvg,
        capFadeAvg = step.capFadeAvg,
        calFadeAvg = step.calFadeAvg,
        cycFadeAvg = step.cycFadeAvg,
        capFadeSpread = step.capFadeSpread,
        sohMin = step.sohMin,
        resGrowthAvg = step.resGrowthAvg,
        calResGrowthAvg = step.calResGrowthAvg,
        cycResGrowthAvg = step.cycResGrowthAvg,
        resGrowthSpread = step.resGrowthSpread,
        moduleCurrentA = step.moduleCurrentA,
        nCellsBalancing = step.nCellsBalancing,
    )
end

function _parse_cell_step(record::Dict, nm::Integer, fallbackSoc::Real, fallbackSoh::Real)
    sohPct = get(record, "soh_avg", nothing)
    sohMinPct = get(record, "soh_min", nothing)
    soh = sohPct isa Real ? float(sohPct) / 100 : float(fallbackSoh)
    sohMin = sohMinPct isa Real ? float(sohMinPct) / 100 : soh
    CellStep(
        _record_float(record, "time"),
        _record_float(record, "module_power_kw") * float(nm),
        _record_float(record, "soc_avg", fallbackSoc),
        soh,
        _record_float(record, "soc_min"),
        _record_float(record, "soc_max"),
        _record_float(record, "cell_v_min"),
        _record_float(record, "cell_v_max"),
        _record_float(record, "cell_v_avg"),
        _record_float(record, "module_voltage"),
        _record_float(record, "temp_min", 25.0),
        _record_float(record, "temp_max", 25.0),
        _record_float(record, "temp_avg", 25.0),
        _record_float(record, "module_current"),
        _record_float(record, "n_cells_balancing"),
        _record_float(record, "cap_fade_avg"),
        _record_float(record, "cal_fade_avg"),
        _record_float(record, "cyc_fade_avg"),
        _record_float(record, "cap_fade_spread"),
        sohMin,
        _record_float(record, "res_growth_avg"),
        _record_float(record, "cal_res_growth_avg"),
        _record_float(record, "cyc_res_growth_avg"),
        _record_float(record, "res_growth_spread"),
    )
end

function _response_records(responseDict)
    records = get(responseDict, "bmsRecords", nothing)
    if records isa Vector
        return [record for record in records if record isa Dict]
    end
    record = get(responseDict, "bmsRecord", nothing)
    return record isa Dict ? Dict[record] : Dict[]
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

function CellLevelLiIonBattery(
    batteryType::AbstractString,
    cellSimulation::Dict,
    bmsController,
)
    chIn = Channel{String}(1)
    chOut = Channel{String}(1)
    task = _start_bms_connection(chIn, chOut)

    ratings = module_ratings(cellSimulation, bmsController)
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

    soc = _bms_nested(responseDict, "SOC", 0.5)
    soh = _bms_nested(responseDict, "SOH", 1.0)
    etaRt = _bms_nested(responseDict, "etaRt", 1.0)
    states = CellLevelStates(
        0.0,
        soc isa Real ? float(soc) : 0.5,
        soh isa Real ? float(soh) : 1.0,
        etaRt isa Real ? float(etaRt) : 1.0,
    )
    return CellLevelLiIonBattery(ratings, states, chIn, chOut, task)
end

ηRT(ess::CellLevelLiIonBattery) = ess.states.eta_rt
self_discharge_rate(::CellLevelLiIonBattery) = 0.0
SOC(ess::CellLevelLiIonBattery) = ess.states.SOC
SOH(ess::CellLevelLiIonBattery) = ess.states.SOH
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

    fallbackSoh = SOH(ess)
    steps = CellStep[
        _parse_cell_step(record, ess.ratings.nm, SOC(ess), fallbackSoh) for
        record in _response_records(responseDict)
    ]
    delivered = _bms_nested(responseDict, "powerKw", powerKw)
    soc = _bms_nested(responseDict, "SOC", SOC(ess))
    soh = _bms_nested(responseDict, "SOH", fallbackSoh)
    ess.states.powerKw = delivered isa Real ? float(delivered) : float(powerKw)
    ess.states.SOC = soc isa Real ? float(soc) : SOC(ess)
    ess.states.SOH = soh isa Real ? float(soh) : fallbackSoh
    etaRt = get(responseDict, "etaRt", nothing)
    if etaRt isa Real
        ess.states.eta_rt = float(etaRt)
    end
    return CellLevelResult(ess.states.powerKw, ess.states.SOC, ess.states.SOH, steps)
end

function initialize_extra_operations(ess::CellLevelLiIonBattery)
    soc = SOC(ess)
    soh = SOH(ess)
    v = ess.ratings.v_cell_nom
    series = Series[
        PointSeries([soh]),
        PointSeries([soc]),
        PointSeries([soc]),
        PointSeries([v]),
        PointSeries([v]),
        PointSeries([v]),
        PointSeries([ess.ratings.ns * v]),
        PointSeries([25.0]),
        PointSeries([25.0]),
        PointSeries([25.0]),
        PointSeries([0.0]),
        PointSeries([0.0]),
        PointSeries([0.0]),
        PointSeries([0.0]),
        PointSeries([soh]),
        PointSeries([0.0]),
        PointSeries([0.0]),
        PointSeries([0.0]),
        PointSeries([0.0]),
        PeriodSeries{Float64}(),
        PeriodSeries{Float64}(),
    ]
    headers = Symbol[
        CELL_POINT_HEADERS...,
        CELL_PERIOD_HEADERS...,
    ]
    return series, headers
end

function CtrlEvalEngine.cleanup(ess::CellLevelLiIonBattery)
    close(ess.chOut)
    wait(ess.task)
end

function append_cell_steps!(
    operation::TimeFrame,
    tEnd::DateTime,
    result::CellLevelResult,
)
    if isempty(result.steps)
        return operation
    end
    origin = operation.t[1]
    for step in result.steps
        stamp = origin + Dates.Millisecond(round(Int, step.elapsedS * 1000))
        if stamp <= operation.t[end]
            stamp = operation.t[end] + Dates.Millisecond(1)
        end
        push!(operation, stamp, operation_point(step))
    end
    return operation
end

function _band(x, y, yLow, yHigh, name)
    Dict(
        :x => x,
        :y => y,
        :yLow => yLow,
        :yHigh => yHigh,
        :type => "band",
        :name => name,
    )
end

function cell_level_charts(operation::TimeFrame)
    if !(:cellVAvg in operation.headers)
        return Any[]
    end
    t = operation.t
    charts = Any[
        Dict(
            :title => "Cell SOC",
            :height => "400px",
            :xAxis => Dict(:title => "Time"),
            :yAxisLeft => Dict(:title => "SOC", :tickformat => ",.0%"),
            :data => [
                _band(
                    t,
                    CtrlEvalEngine.column_data(operation, :SOC),
                    CtrlEvalEngine.column_data(operation, :cellSocMin),
                    CtrlEvalEngine.column_data(operation, :cellSocMax),
                    "Cell SOC",
                ),
            ],
        ),
        Dict(
            :title => "Cell Voltage",
            :height => "400px",
            :xAxis => Dict(:title => "Time"),
            :yAxisLeft => Dict(:title => "Voltage (V)"),
            :data => [
                _band(
                    t,
                    CtrlEvalEngine.column_data(operation, :cellVAvg),
                    CtrlEvalEngine.column_data(operation, :cellVMin),
                    CtrlEvalEngine.column_data(operation, :cellVMax),
                    "Cell Voltage",
                ),
                Dict(
                    :x => t,
                    :y => CtrlEvalEngine.column_data(operation, :moduleVoltage),
                    :type => "instance",
                    :name => "Module Voltage",
                    :yAxis => "right",
                ),
            ],
            :yAxisRight => Dict(:title => "Module Voltage (V)"),
        ),
        Dict(
            :title => "Temperature and Balancing",
            :height => "400px",
            :xAxis => Dict(:title => "Time"),
            :yAxisLeft => Dict(:title => "Temperature (C)"),
            :yAxisRight => Dict(:title => "Cells Balancing"),
            :data => [
                _band(
                    t,
                    CtrlEvalEngine.column_data(operation, :tempAvg),
                    CtrlEvalEngine.column_data(operation, :tempMin),
                    CtrlEvalEngine.column_data(operation, :tempMax),
                    "Temperature",
                ),
                Dict(
                    :x => t,
                    :y => CtrlEvalEngine.column_data(operation, :nCellsBalancing),
                    :type => "interval",
                    :name => "Cells Balancing",
                    :yAxis => "right",
                ),
            ],
        ),
        Dict(
            :title => "Module Current",
            :height => "400px",
            :xAxis => Dict(:title => "Time"),
            :yAxisLeft => Dict(:title => "Module current (A)"),
            :data => [
                Dict(
                    :x => t,
                    :y => CtrlEvalEngine.column_data(operation, :moduleCurrentA),
                    :type => "interval",
                    :name => "Module Current",
                ),
            ],
        ),
    ]
    fade = CtrlEvalEngine.column_data(operation, :capFadeAvg)
    if any(value -> value != 0, fade)
        push!(
            charts,
            Dict(
                :title => "Capacity Fade",
                :height => "400px",
                :xAxis => Dict(:title => "Time"),
                :yAxisLeft => Dict(:title => "Capacity Fade", :tickformat => ",.2%"),
                :data => [
                    Dict(:x => t, :y => fade, :type => "instance", :name => "Total Avg"),
                    Dict(
                        :x => t,
                        :y => CtrlEvalEngine.column_data(operation, :calFadeAvg),
                        :type => "instance",
                        :name => "Calendar Avg",
                    ),
                    Dict(
                        :x => t,
                        :y => CtrlEvalEngine.column_data(operation, :cycFadeAvg),
                        :type => "instance",
                        :name => "Cycle Avg",
                    ),
                    Dict(
                        :x => t,
                        :y => CtrlEvalEngine.column_data(operation, :capFadeSpread),
                        :type => "instance",
                        :name => "Cell Spread",
                    ),
                ],
            ),
            Dict(
                :title => "Cell State of Health",
                :height => "400px",
                :xAxis => Dict(:title => "Time"),
                :yAxisLeft => Dict(:title => "SOH", :tickformat => ",.0%"),
                :data => [
                    Dict(:x => t, :y => CtrlEvalEngine.column_data(operation, :SOH), :type => "instance", :name => "SOH Avg"),
                    Dict(:x => t, :y => CtrlEvalEngine.column_data(operation, :sohMin), :type => "instance", :name => "SOH Min"),
                ],
            ),
            Dict(
                :title => "Resistance Growth",
                :height => "400px",
                :xAxis => Dict(:title => "Time"),
                :yAxisLeft => Dict(:title => "Resistance Growth", :tickformat => ",.2%"),
                :data => [
                    Dict(
                        :x => t,
                        :y => CtrlEvalEngine.column_data(operation, :resGrowthAvg),
                        :type => "instance",
                        :name => "Total Avg",
                    ),
                    Dict(
                        :x => t,
                        :y => CtrlEvalEngine.column_data(operation, :calResGrowthAvg),
                        :type => "instance",
                        :name => "Calendar Avg",
                    ),
                    Dict(
                        :x => t,
                        :y => CtrlEvalEngine.column_data(operation, :cycResGrowthAvg),
                        :type => "instance",
                        :name => "Cycle Avg",
                    ),
                    Dict(
                        :x => t,
                        :y => CtrlEvalEngine.column_data(operation, :resGrowthSpread),
                        :type => "instance",
                        :name => "Cell Spread",
                    ),
                ],
            ),
        )
    end
    return charts
end
