"""
    ActivePowerSmoothingMode(params; WSmthGra, WSmthLoLim=0, WSmthHiLim=0, FilTms, rampParams, EcpRef)

Active Power Smoothing (IEEE 1815.2 6.4.8; 61850 DWSM). Type Additive; mutually exclusive with AGC.

The reference power (the signal meter, by default the `VariabilityMitigation` PV profile) is averaged over `FilTms`
seconds. Delta wattage = reference − moving average. No action while the delta lies in [`WSmthLoLim`, `WSmthHiLim`]
(kW). Otherwise the additional power is `WSmthGra` × delta: a positive gradient follows load, a negative one follows
generation (6.4.8). Ramp rates only (Table 23). The attempted output is DWSM.ReqWSet.
"""
mutable struct ActivePowerSmoothingMode <: MesaMode
    params::MesaModeParams
    WSmthGra::Float64
    WSmthLoLim::Float64
    WSmthHiLim::Float64
    FilTms::Dates.Second
    rampParams::RampParams
    EcpRef::Symbol
    filter::MovingAverage
end

function ActivePowerSmoothingMode(
    params::MesaModeParams;
    WSmthGra::Real,
    WSmthLoLim::Real = 0.0,
    WSmthHiLim::Real = 0.0,
    FilTms,
    rampParams::RampParams = RampParams(),
    EcpRef::Symbol = :default,
)
    WSmthLoLim <= WSmthHiLim || throw(ArgumentError("Active Power Smoothing: WSmthLoLim must be ≤ WSmthHiLim"))
    ActivePowerSmoothingMode(
        params,
        Float64(WSmthGra),
        Float64(WSmthLoLim),
        Float64(WSmthHiLim),
        _sec(FilTms),
        rampParams,
        EcpRef,
        MovingAverage(_sec(FilTms)),
    )
end

kind(::Type{ActivePowerSmoothingMode}) = Additive()
response_limiting(::ActivePowerSmoothingMode) = (false, true)
power_sources(::Type{ActivePowerSmoothingMode}) =
    (VariabilityMitigation, LoadFollowing, GenerationFollowing, PeakLimiting)
reset_state!(mode::ActivePowerSmoothingMode) = (reset!(mode.filter); nothing)

function modecontrol(
    mode::ActivePowerSmoothingMode,
    ::EnergyStorageSystem,
    controller::MesaController,
    ::TimeFrameRow,
    useCases::AbstractVector{<:UseCase},
    t::DateTime,
    _,
    ::ControlContext,
)
    sig = read_signal(controller, useCases, mode, :W, t)
    sig === nothing && return nothing
    reference, _ = sig
    avg = isempty(mode.filter.values) ? reference : average(mode.filter)
    push_sample!(mode.filter, t, reference)
    deltaW = reference - avg
    if mode.WSmthLoLim <= deltaW <= mode.WSmthHiLim
        return abs(previous_WIP(mode)) > 1e-9 ? Delta(0.0) : nothing
    end
    return Delta(mode.WSmthGra * deltaW)
end
