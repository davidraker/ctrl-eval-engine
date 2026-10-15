"""
Construction of a `MesaController` from the engine's input dictionary (`"rtController": {"type": "mesa", ...}`).

```json
{
  "type": "mesa", "resolutionSec": 4,
  "OpnLoopTau": true, "OplPct": 90,
  "maxRampRates": {"RpuRteMax": 20, "RpdRteMax": 20, "RpuChaRteMax": 20, "RpdChaRteMax": 20},
  "SocUseMinPct": 10, "SocUseMaxPct": 90,
  "randomSeed": 1,
  "meters": {"pcc": {"HzNom": 60, "VRef": 120}},
  "modes": [
    {"type": "chargeDischarge", "ModPrio": 2, "GnWPctSpt": 53, "UseRmpRte": true,
     "RpuRte": 10, "RpdRte": 20, "RpuChaRte": 10, "RpdChaRte": 20},
    {"type": "activePowerLimit", "ModPrio": 1, "LimWMax": 80, "LimWMin": -50},
    {"type": "frequencyWattDroop", "ModPrio": 1, "EcpRef": "pcc", "HzStrHi": 60.036, "HzStrLo": 59.964, "WGraHi": 5}
  ]
}
```

Mode keys are the 61850 data object names used by the constructors. Shared keys: `ModPrio` (or `priority`), `ModEna`
(or `enabled`), `WinTms`, `RmpTms`, `RvrtTms` (seconds; or `enablingTimeWindowSec`, `enablingRampTimeSec`,
`reversionTimeoutSec`). Ramp keys `RpuRte`, `RpdRte`, `RpuChaRte`, `RpdChaRte` (percent per second) and `RmpUpTms`,
`RmpDnTms` (seconds) are collected into the mode's `RampParams`. Curves are `{"crvPts": [{"xVal", "yVal"}, ...]}` or
`[[x, y], ...]`. Mode `type` accepts the camelCase names below or the 61850 logical node class (`DWGC`, `DWMX`,
`DAGC`, `DTCD`, `DHFW`, `DVWC`, `DVWD`, `DWSM`, `DWFL1`, `DWFL2`, `DWFL3`).
"""

const SHARED_KEYS = Set([
    "type", "ModPrio", "priority", "ModEna", "enabled",
    "WinTms", "RmpTms", "RvrtTms", "enablingTimeWindowSec", "enablingRampTimeSec", "reversionTimeoutSec",
    "RpuRte", "RpdRte", "RpuChaRte", "RpdChaRte", "RmpUpTms", "RmpDnTms",
    "DschRpuRte", "DschRpdRte", "ChaRpuRte", "ChaRpdRte",
])

const MODE_TYPES = Dict{String,Any}(
    "chargeDischarge" => ChargeDischargeStorageMode,
    "DWGC" => ChargeDischargeStorageMode,
    "activePowerLimit" => ActivePowerLimitMode,
    "DWMX" => ActivePowerLimitMode,
    "agc" => AGCMode,
    "DAGC" => AGCMode,
    "coordinatedChargeDischarge" => CoordinatedChargeDischargeMode,
    "DTCD" => CoordinatedChargeDischargeMode,
    "frequencyWatt" => FrequencyWattMode,
    "DHFW1" => FrequencyWattMode,
    "frequencyWattCurve" => FrequencyWattCurveMode,
    "DHFW2" => FrequencyWattCurveMode,
    "frequencyWattDroop" => FrequencyWattDroopMode,
    "DHFW3" => FrequencyWattDroopMode,
    "DHFW" => FrequencyWattMode,
    "voltWatt" => VoltWattMode,
    "DVWC" => VoltWattMode,
    "dynamicVoltWatt" => DynamicVoltWattMode,
    "DVWD" => DynamicVoltWattMode,
    "activePowerSmoothing" => ActivePowerSmoothingMode,
    "DWSM" => ActivePowerSmoothingMode,
    "peakPowerLimiting" => PeakPowerLimitingMode,
    "DWFL1" => PeakPowerLimitingMode,
    "loadFollowing" => LoadFollowingMode,
    "DWFL2" => LoadFollowingMode,
    "generationFollowing" => GenerationFollowingMode,
    "DWFL3" => GenerationFollowingMode,
)

_first_key(cfg::AbstractDict, keys...; default = nothing) = begin
    for k in keys
        haskey(cfg, k) && return cfg[k]
    end
    default
end

function build_mode_params(cfg::AbstractDict)
    MesaModeParams(
        Int(_first_key(cfg, "ModPrio", "priority"; default = 0));
        ModEna = Bool(_first_key(cfg, "ModEna", "enabled"; default = true)),
        WinTms = _first_key(cfg, "WinTms", "enablingTimeWindowSec"; default = 0),
        RmpTms = _first_key(cfg, "RmpTms", "enablingRampTimeSec"; default = 0),
        RvrtTms = _first_key(cfg, "RvrtTms", "reversionTimeoutSec"; default = 0),
    )
end

function build_ramp_params(cfg::AbstractDict)
    RampParams(;
        RpuRte = _first_key(cfg, "RpuRte", "DschRpuRte"),
        RpdRte = _first_key(cfg, "RpdRte", "DschRpdRte"),
        RpuChaRte = _first_key(cfg, "RpuChaRte", "ChaRpuRte"),
        RpdChaRte = _first_key(cfg, "RpdChaRte", "ChaRpdRte"),
        RmpUpTms = get(cfg, "RmpUpTms", nothing),
        RmpDnTms = get(cfg, "RmpDnTms", nothing),
    )
end

const CURVE_KEYS = Set(["HzWCrv", "VWCrv", "VWCrvLo"])
const SYMBOL_KEYS = Set(["EcpRef"])
const DATETIME_KEYS = Set(["DateTgt"])

function _coerce(key::String, value)
    key in CURVE_KEYS && return VertexCurve(value)
    key in SYMBOL_KEYS && return Symbol(value)
    key in DATETIME_KEYS && return value isa DateTime ? value : DateTime(value)
    return value
end

"""
    build_mode(cfg::AbstractDict) -> MesaMode

Build one mode from its configuration dictionary (see the module docstring for the keys).
"""
function build_mode(cfg::AbstractDict)
    typeName = String(cfg["type"])
    T = get(MODE_TYPES, typeName, nothing)
    T === nothing && throw(InvalidInput("Unknown MESA mode type: $typeName"))
    params = build_mode_params(cfg)
    kwargs = Dict{Symbol,Any}(Symbol(k) => _coerce(String(k), v) for (k, v) in cfg if !(String(k) in SHARED_KEYS))
    if hasfield(T, :rampParams)
        kwargs[:rampParams] = build_ramp_params(cfg)
    end
    try
        return T(params; kwargs...)
    catch e
        e isa MethodError && throw(InvalidInput("Invalid parameters for MESA mode $typeName: $(join(keys(kwargs), ", "))"))
        rethrow()
    end
end

function build_meters(cfg::AbstractDict)
    meters = Dict{Symbol,MeterReadings}()
    for (name, m) in cfg
        meters[Symbol(name)] = MeterReadings(;
            W = get(m, "W", nothing),
            V = get(m, "V", nothing),
            Hz = get(m, "Hz", nothing),
            VRef = get(m, "VRef", nothing),
            HzNom = get(m, "HzNom", 60.0),
        )
    end
    return meters
end

"""
    build_mesa_controller(config::AbstractDict, resolution::Dates.Period) -> MesaController
"""
function build_mesa_controller(config::AbstractDict, resolution::Dates.Period)
    modes = [build_mode(m) for m in get(config, "modes", [])]
    mr = get(config, "maxRampRates", Dict{String,Any}())
    maxRampRates = RampParams(;
        RpuRte = get(mr, "RpuRteMax", nothing),
        RpdRte = get(mr, "RpdRteMax", nothing),
        RpuChaRte = get(mr, "RpuChaRteMax", nothing),
        RpdChaRte = get(mr, "RpdChaRteMax", nothing),
    )
    reserves = get(config, "storageReserves", Dict{String,Any}())
    seed = get(config, "randomSeed", nothing)
    return MesaController(
        modes,
        resolution;
        maxRampRates,
        SocUseMinPct = _first_key(config, "SocUseMinPct"; default = get(reserves, "SocUseMinPct", 0.0)),
        SocUseMaxPct = _first_key(config, "SocUseMaxPct"; default = get(reserves, "SocUseMaxPct", 100.0)),
        OpnLoopTau = Bool(get(config, "OpnLoopTau", get(config, "timeConstantMode", "openLoop") == "openLoop")),
        OplPct = get(config, "OplPct", get(config, "openLoopResponsePct", 90.0)),
        randomSeed = seed === nothing ? nothing : Int(seed),
        meters = build_meters(get(config, "meters", Dict{String,Any}())),
    )
end
