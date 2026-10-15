"""
    DynamicVoltWattMode(params; DynVWGra, DbVWLo=0, DbVWHi=0, VWFilTms, EcpRef)

Dynamic Volt-Watt (IEEE 1815.2 6.4.10; 61850 DVWD). Type Additive.

The voltage's moving average over `VWFilTms` seconds is the reference; the percent delta voltage is
(V − average) / VRef × 100. Inside the deadband [`DbVWLo`, `DbVWHi`] (percent, `DbVWLo` ≤ 0 ≤ `DbVWHi`) there is no
action. Outside it the additional power is −`DynVWGra` × delta, in percent of `WMax` (positive) or `ChaWMax`
(negative): rising voltage absorbs, falling voltage injects. The attempted output is DVWD.ReqWSet.
"""
mutable struct DynamicVoltWattMode <: MesaMode
    params::MesaModeParams
    DynVWGra::Float64
    DbVWLo::Float64
    DbVWHi::Float64
    VWFilTms::Dates.Second
    EcpRef::Symbol
    filter::MovingAverage
end

function DynamicVoltWattMode(
    params::MesaModeParams;
    DynVWGra::Real,
    DbVWLo::Real = 0.0,
    DbVWHi::Real = 0.0,
    VWFilTms,
    EcpRef::Symbol = :default,
)
    DbVWLo <= 0 <= DbVWHi || throw(ArgumentError("Dynamic Volt-Watt deadband must satisfy DbVWLo ≤ 0 ≤ DbVWHi"))
    DynamicVoltWattMode(
        params,
        Float64(DynVWGra),
        Float64(DbVWLo),
        Float64(DbVWHi),
        _sec(VWFilTms),
        EcpRef,
        MovingAverage(_sec(VWFilTms)),
    )
end

kind(::Type{DynamicVoltWattMode}) = Additive()
reset_state!(mode::DynamicVoltWattMode) = (reset!(mode.filter); nothing)

function modecontrol(
    mode::DynamicVoltWattMode,
    ess::EnergyStorageSystem,
    controller::MesaController,
    ::TimeFrameRow,
    useCases::AbstractVector{<:UseCase},
    t::DateTime,
    _,
    ::ControlContext,
)
    sig = read_signal(controller, useCases, mode, :V, t)
    sig === nothing && return nothing
    v, VRef = sig
    VRef === nothing && error("DynamicVoltWattMode needs a reference voltage (VRef) on its meter or use case")
    avg = isempty(mode.filter.values) ? v : average(mode.filter)
    push_sample!(mode.filter, t, v)
    deltaPct = (v - avg) / VRef * 100
    if mode.DbVWLo <= deltaPct <= mode.DbVWHi
        return abs(previous_WIP(mode)) > 1e-9 ? Delta(0.0) : nothing
    end
    addPct = -mode.DynVWGra * deltaPct
    return Delta(pct_to_kw(addPct, p_max(ess), abs(p_min(ess))))
end
