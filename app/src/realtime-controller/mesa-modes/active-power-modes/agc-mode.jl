"""
    AGCMode(params; WSpt, UseRmpRte=true, rampParams=RampParams(), SocUseMinPct, SocUseMaxPct)

Automatic Generation Control (IEEE 1815.2 6.4.7; 61850 DAGC). Type Replacing; mutually exclusive with every other
active power function except Charge/Discharge Storage and Active Power Limiting (Table 58).

The target is `WSpt` (kW, DAGC.WSpt, updated by the controlling station) when set; otherwise, when a `Regulation`
use case is present, the engine's per-unit convention: the schedule period's regulation capacity times the AGC
signal. Without either the mode is enabled but inactive. `SocUseMinPct`/`SocUseMaxPct` is the function's own usable
SOC window: outside it the target is held at zero. Status extras report `WMaxAvl`, `WMinAvl` and the SOC expected
after one step at the target (`SocExpc`).
"""
mutable struct AGCMode <: MesaMode
    params::MesaModeParams
    WSpt::Union{Float64,Nothing}
    UseRmpRte::Bool
    rampParams::RampParams
    SocUseMinPct::Union{Float64,Nothing}
    SocUseMaxPct::Union{Float64,Nothing}
end

AGCMode(
    params::MesaModeParams;
    WSpt = nothing,
    UseRmpRte::Bool = true,
    rampParams::RampParams = RampParams(),
    SocUseMinPct = nothing,
    SocUseMaxPct = nothing,
) = AGCMode(params, _fl(WSpt), UseRmpRte, rampParams, _fl(SocUseMinPct), _fl(SocUseMaxPct))

kind(::Type{AGCMode}) = Replacing()
response_limiting(mode::AGCMode) = (!mode.UseRmpRte, mode.UseRmpRte)
mutually_exclusive(::Type{AGCMode}, ::Type{T}) where {T<:MesaMode} =
    !(T <: Union{ChargeDischargeStorageMode,ActivePowerLimitMode})

function agc_target(mode::AGCMode, schedulePeriod::TimeFrameRow, useCases, t::DateTime)
    mode.WSpt !== nothing && return mode.WSpt
    idx = findfirst(uc -> uc isa Regulation, useCases)
    idx === nothing && return nothing
    signalPu = Float64(get_period(useCases[idx].AGCSignalPu, t)[1])
    return regulation_capacity(schedulePeriod) * signalPu
end

function modecontrol(
    mode::AGCMode,
    ess::EnergyStorageSystem,
    ::MesaController,
    schedulePeriod::TimeFrameRow,
    useCases::AbstractVector{<:UseCase},
    t::DateTime,
    _,
    ::ControlContext,
)
    target = agc_target(mode, schedulePeriod, useCases, t)
    target === nothing && return nothing
    within_soc_window(ess, target, mode.SocUseMinPct, mode.SocUseMaxPct) || return Setpoint(0.0)
    return Setpoint(target)
end

function status_extras(mode::AGCMode, ess::EnergyStorageSystem, ctx::ControlContext)
    duration = Dates.Millisecond(round(Int, ctx.dt * 1000))
    hours = ctx.dt / 3600
    expected = e_max(ess) > 0 ? (energy_state(ess) - mode.params.attempted * hours) / e_max(ess) * 100 : 0.0
    return Dict(
        :WMaxAvl => p_max(ess, duration),
        :WMinAvl => p_min(ess, duration),
        :SocExpc => clamp(expected, 0.0, 100.0),
    )
end
