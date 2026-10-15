"""
Frequency-Watt functions (IEEE 1815.2 6.4.3 droop and sensitivity, 6.4.9 curve; 61850 DHFW for the high side,
DLFW for the low side). All three are type Additive and share one state machine:

- inactive → high when frequency stays above `HzStrHi` for `ActStrDlTmms`; high → inactive when it stays at or below
  `HzStopHi` for `ActStopDlTmms`; the low side mirrors this with `HzStrLo`/`HzStopLo`.
- On activation the ESS's actual power is captured as the snapshot (Psnapshot).
- With `SnptEna` the target moves from the snapshot along the gradient; without it the function is a boundary the
  base may not cross. With `HysEna` the target holds its most extreme value until deactivation.
- `SocUseMinPct`/`SocUseMaxPct` is the function's own SOC window; outside it the contribution is zero.
- After deactivation the contribution returns to zero, limited by `RtnRmpRte` (percent of WMax per second) when set
  and by the function's ramp parameters.

Field suffixes `Hi`/`Lo` map to the DHFW/DLFW instances of the same data object.
"""

abstract type AbstractFrequencyWattMode <: MesaMode end

mutable struct FWState
    side::Symbol                          # :inactive, :high, :low
    timerStart::Union{DateTime,Nothing}
    snapshotKw::Float64
    extremeKw::Float64
end
FWState() = FWState(:inactive, nothing, 0.0, 0.0)

"""
    FrequencyWattMode(params; HzStrHi, HzStopHi, HzStrLo, HzStopLo, WGraHi, WChaGraHi, WGraLo, WChaGraLo, kwargs...)

Frequency-Watt sensitivity (6.4.3.3; DHFW1/DLFW1). Gradients are percent of `WMax` (discharging side, `WGra*`) or of
`ChaWMax` (charging side, `WChaGra*`) per percent frequency deviation from nominal. Keywords shared with the other
Frequency-Watt modes: `ActStrDlTmms`, `ActStopDlTmms` (milliseconds), `SnptEna=true`, `HysEna=false`, `SocUseMinPct`,
`SocUseMaxPct`, `RtnRmpRte`, `rampParams`, `EcpRef`.
"""
mutable struct FrequencyWattMode <: AbstractFrequencyWattMode
    params::MesaModeParams
    HzStrHi::Float64
    HzStopHi::Float64
    HzStrLo::Float64
    HzStopLo::Float64
    WGraHi::Float64
    WChaGraHi::Float64
    WGraLo::Float64
    WChaGraLo::Float64
    ActStrDlTmms::Dates.Millisecond
    ActStopDlTmms::Dates.Millisecond
    SnptEna::Bool
    HysEna::Bool
    SocUseMinPct::Union{Float64,Nothing}
    SocUseMaxPct::Union{Float64,Nothing}
    RtnRmpRte::Union{Float64,Nothing}
    rampParams::RampParams
    EcpRef::Symbol
    state::FWState
end

function FrequencyWattMode(
    params::MesaModeParams;
    HzStrHi::Real,
    HzStopHi::Real = HzStrHi,
    HzStrLo::Real,
    HzStopLo::Real = HzStrLo,
    WGraHi::Real,
    WChaGraHi::Real = WGraHi,
    WGraLo::Real,
    WChaGraLo::Real = WGraLo,
    ActStrDlTmms = 0,
    ActStopDlTmms = 0,
    SnptEna::Bool = true,
    HysEna::Bool = false,
    SocUseMinPct = nothing,
    SocUseMaxPct = nothing,
    RtnRmpRte = nothing,
    rampParams::RampParams = RampParams(),
    EcpRef::Symbol = :default,
)
    FrequencyWattMode(
        params,
        Float64(HzStrHi),
        Float64(HzStopHi),
        Float64(HzStrLo),
        Float64(HzStopLo),
        Float64(WGraHi),
        Float64(WChaGraHi),
        Float64(WGraLo),
        Float64(WChaGraLo),
        _ms(ActStrDlTmms),
        _ms(ActStopDlTmms),
        SnptEna,
        HysEna,
        _fl(SocUseMinPct),
        _fl(SocUseMaxPct),
        _fl(RtnRmpRte),
        rampParams,
        EcpRef,
        FWState(),
    )
end

"""
    FrequencyWattDroopMode(params; HzStrHi, HzStrLo, WGraHi, WGraLo, WMinPct=-100, WMaxPct=100, kwargs...)

Frequency-Watt droop (6.4.3.1; DHFW3/DLFW3; IEEE 1547 primary frequency response). `HzStrHi`/`HzStrLo` are the
deadband edges; the gradient is percent of `WMax` per percent frequency deviation beyond the edge, applied from the
pre-disturbance power (the snapshot). `WMinPct` (DHFW3.WMin) and `WMaxPct` (DLFW3.WMax) bound the result in percent
of `WMax`, negative meaning charging. Shared keywords as for `FrequencyWattMode`; the open-loop response time goes in
`rampParams.RmpUpTms`/`RmpDnTms`.
"""
mutable struct FrequencyWattDroopMode <: AbstractFrequencyWattMode
    params::MesaModeParams
    HzStrHi::Float64
    HzStopHi::Float64
    HzStrLo::Float64
    HzStopLo::Float64
    WGraHi::Float64
    WGraLo::Float64
    WMinPct::Float64
    WMaxPct::Float64
    ActStrDlTmms::Dates.Millisecond
    ActStopDlTmms::Dates.Millisecond
    SnptEna::Bool
    HysEna::Bool
    SocUseMinPct::Union{Float64,Nothing}
    SocUseMaxPct::Union{Float64,Nothing}
    RtnRmpRte::Union{Float64,Nothing}
    rampParams::RampParams
    EcpRef::Symbol
    state::FWState
end

function FrequencyWattDroopMode(
    params::MesaModeParams;
    HzStrHi::Real,
    HzStopHi::Real = HzStrHi,
    HzStrLo::Real,
    HzStopLo::Real = HzStrLo,
    WGraHi::Real,
    WGraLo::Real = WGraHi,
    WMinPct::Real = -100.0,
    WMaxPct::Real = 100.0,
    ActStrDlTmms = 0,
    ActStopDlTmms = 0,
    HysEna::Bool = false,
    SocUseMinPct = nothing,
    SocUseMaxPct = nothing,
    RtnRmpRte = nothing,
    rampParams::RampParams = RampParams(),
    EcpRef::Symbol = :default,
)
    FrequencyWattDroopMode(
        params,
        Float64(HzStrHi),
        Float64(HzStopHi),
        Float64(HzStrLo),
        Float64(HzStopLo),
        Float64(WGraHi),
        Float64(WGraLo),
        Float64(WMinPct),
        Float64(WMaxPct),
        _ms(ActStrDlTmms),
        _ms(ActStopDlTmms),
        true,
        HysEna,
        _fl(SocUseMinPct),
        _fl(SocUseMaxPct),
        _fl(RtnRmpRte),
        rampParams,
        EcpRef,
        FWState(),
    )
end

"""
    FrequencyWattCurveMode(params; HzWCrv, HzStrHi, HzStrLo, kwargs...)

Frequency-Watt curve (6.4.9; DHFW2/DLFW2). `HzWCrv` maps percent frequency deviation from nominal (x) to percent of
`WMax` (y, negative meaning percent of `ChaWMax` charging). With `SnptEna` the target is the snapshot plus the curve's
change since the start frequency; without it the curve is a boundary. Shared keywords as for `FrequencyWattMode`.
"""
mutable struct FrequencyWattCurveMode <: AbstractFrequencyWattMode
    params::MesaModeParams
    HzWCrv::VertexCurve
    HzStrHi::Float64
    HzStopHi::Float64
    HzStrLo::Float64
    HzStopLo::Float64
    ActStrDlTmms::Dates.Millisecond
    ActStopDlTmms::Dates.Millisecond
    SnptEna::Bool
    HysEna::Bool
    SocUseMinPct::Union{Float64,Nothing}
    SocUseMaxPct::Union{Float64,Nothing}
    RtnRmpRte::Union{Float64,Nothing}
    rampParams::RampParams
    EcpRef::Symbol
    state::FWState
end

function FrequencyWattCurveMode(
    params::MesaModeParams;
    HzWCrv,
    HzStrHi::Real,
    HzStopHi::Real = HzStrHi,
    HzStrLo::Real,
    HzStopLo::Real = HzStrLo,
    ActStrDlTmms = 0,
    ActStopDlTmms = 0,
    SnptEna::Bool = true,
    HysEna::Bool = false,
    SocUseMinPct = nothing,
    SocUseMaxPct = nothing,
    RtnRmpRte = nothing,
    rampParams::RampParams = RampParams(),
    EcpRef::Symbol = :default,
)
    FrequencyWattCurveMode(
        params,
        HzWCrv isa VertexCurve ? HzWCrv : VertexCurve(HzWCrv),
        Float64(HzStrHi),
        Float64(HzStopHi),
        Float64(HzStrLo),
        Float64(HzStopLo),
        _ms(ActStrDlTmms),
        _ms(ActStopDlTmms),
        SnptEna,
        HysEna,
        _fl(SocUseMinPct),
        _fl(SocUseMaxPct),
        _fl(RtnRmpRte),
        rampParams,
        EcpRef,
        FWState(),
    )
end

_ms(x::Dates.Period) = Dates.Millisecond(x)
_ms(x::Real) = Dates.Millisecond(round(Int, x))

kind(::Type{<:AbstractFrequencyWattMode}) = Additive()
response_limiting(::AbstractFrequencyWattMode) = (true, true)   # Table 23: time constants, then ramp rates

function reset_state!(mode::AbstractFrequencyWattMode)
    mode.state = FWState()
    return nothing
end

function _fw_activate!(st::FWState, side::Symbol, actualKw::Float64)
    st.side = side
    st.timerStart = nothing
    st.snapshotKw = actualKw
    st.extremeKw = side === :high ? Inf : -Inf
end

function _fw_update_state!(mode::AbstractFrequencyWattMode, f::Float64, t::DateTime, ctx::ControlContext)
    st = mode.state
    if st.side === :inactive
        if f > mode.HzStrHi || f < mode.HzStrLo
            st.timerStart === nothing && (st.timerStart = t)
            if t - st.timerStart >= mode.ActStrDlTmms
                _fw_activate!(st, f > mode.HzStrHi ? :high : :low, ctx.actualKw)
            end
        else
            st.timerStart = nothing
        end
    else
        stopped = st.side === :high ? f <= mode.HzStopHi : f >= mode.HzStopLo
        if stopped
            st.timerStart === nothing && (st.timerStart = t)
            if t - st.timerStart >= mode.ActStopDlTmms
                st.side = :inactive
                st.timerStart = nothing
            end
        else
            st.timerStart = nothing
        end
    end
    return st
end

"""
Move `ref` by a deviation of `dev` percent along the two-gradient sensitivity law: `gDis` percent of WMax per percent
while the result stays on the discharging side of zero, `gCha` percent of ChaWMax per percent beyond it.
`direction` is -1 to reduce output (high frequency) or +1 to increase it (low frequency).
"""
function _shift_along_gradients(ref::Float64, dev::Float64, gDis::Float64, gCha::Float64, WMax::Float64, ChaWMax::Float64, direction::Int)
    dev <= 0 && return ref
    if direction < 0                       # reduce output
        if ref > 0
            kwPerPct = gDis / 100 * WMax
            kwPerPct <= 0 && return ref
            devToZero = ref / kwPerPct
            dev <= devToZero && return ref - kwPerPct * dev
            return -(gCha / 100 * ChaWMax) * (dev - devToZero)
        else
            return ref - gCha / 100 * ChaWMax * dev
        end
    else                                   # increase output
        if ref < 0
            kwPerPct = gCha / 100 * ChaWMax
            kwPerPct <= 0 && return ref
            devToZero = -ref / kwPerPct
            dev <= devToZero && return ref + kwPerPct * dev
            return (gDis / 100 * WMax) * (dev - devToZero)
        else
            return ref + gDis / 100 * WMax * dev
        end
    end
end

"Target power (kW) of the sensitivity law for the active side."
function fw_target(mode::FrequencyWattMode, f::Float64, HzNom::Float64, ess::EnergyStorageSystem, base::Float64)
    st = mode.state
    WMax, ChaWMax = p_max(ess), abs(p_min(ess))
    dev = abs(f - HzNom) / HzNom * 100
    if st.side === :high
        ref = mode.SnptEna ? st.snapshotKw : WMax
        target = _shift_along_gradients(ref, dev, mode.WGraHi, mode.WChaGraHi, WMax, ChaWMax, -1)
        return mode.SnptEna ? target : min(base, target)
    else
        ref = mode.SnptEna ? st.snapshotKw : -ChaWMax
        target = _shift_along_gradients(ref, dev, mode.WGraLo, mode.WChaGraLo, WMax, ChaWMax, +1)
        return mode.SnptEna ? target : max(base, target)
    end
end

"Target power (kW) of the droop law: gradient beyond the deadband edge from the pre-disturbance power."
function fw_target(mode::FrequencyWattDroopMode, f::Float64, HzNom::Float64, ess::EnergyStorageSystem, ::Float64)
    st = mode.state
    WMax = p_max(ess)
    if st.side === :high
        dev = max(f - mode.HzStrHi, 0.0) / HzNom * 100
        return max(st.snapshotKw - mode.WGraHi / 100 * WMax * dev, mode.WMinPct / 100 * WMax)
    else
        dev = max(mode.HzStrLo - f, 0.0) / HzNom * 100
        return min(st.snapshotKw + mode.WGraLo / 100 * WMax * dev, mode.WMaxPct / 100 * WMax)
    end
end

"Target power (kW) of the curve law."
function fw_target(mode::FrequencyWattCurveMode, f::Float64, HzNom::Float64, ess::EnergyStorageSystem, base::Float64)
    st = mode.state
    WMax, ChaWMax = p_max(ess), abs(p_min(ess))
    dev = (f - HzNom) / HzNom * 100
    curveKw = pct_to_kw(evaluate_curve(mode.HzWCrv, dev), WMax, ChaWMax)
    if mode.SnptEna
        hzStr = st.side === :high ? mode.HzStrHi : mode.HzStrLo
        devStr = (hzStr - HzNom) / HzNom * 100
        startKw = pct_to_kw(evaluate_curve(mode.HzWCrv, devStr), WMax, ChaWMax)
        return st.snapshotKw + (curveKw - startKw)
    else
        return st.side === :high ? min(base, curveKw) : max(base, curveKw)
    end
end

function modecontrol(
    mode::AbstractFrequencyWattMode,
    ess::EnergyStorageSystem,
    controller::MesaController,
    ::TimeFrameRow,
    useCases::AbstractVector{<:UseCase},
    t::DateTime,
    _,
    ctx::ControlContext,
)
    sig = read_signal(controller, useCases, mode, :Hz, t)
    sig === nothing && return nothing
    f, HzNom = sig
    st = _fw_update_state!(mode, f, t, ctx)
    base = ctx.baseKw
    if st.side === :inactive
        prev = previous_WIP(mode)
        abs(prev) < 1e-9 && return nothing
        # Return toward zero contribution at the return ramp rate; the controller applies rampParams as well.
        if mode.RtnRmpRte !== nothing
            rp = RampParams(mode.RtnRmpRte, mode.RtnRmpRte, mode.RtnRmpRte, mode.RtnRmpRte)
            return Delta(ramp_toward(prev, 0.0, ctx.dt, rp, p_max(ess), abs(p_min(ess))))
        end
        return Delta(0.0)
    end
    target = fw_target(mode, f, HzNom, ess, base)
    if mode.HysEna
        target = st.side === :high ? min(target, st.extremeKw) : max(target, st.extremeKw)
    end
    st.extremeKw = target
    delta = target - base
    within_soc_window(ess, delta, mode.SocUseMinPct, mode.SocUseMaxPct) || return Delta(0.0)
    return Delta(delta)
end
