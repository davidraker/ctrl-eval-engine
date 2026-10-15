"""
    VoltWattMode(params; VWCrv, VWCrvLo=nothing, VRefOfs=0, FilTms=nothing, UseRmpRte=false, rampParams, EcpRef)

Volt-Watt (IEEE 1815.2 6.4.4; 61850 DVWC). Type Additive (Table 58), composed as a boundary: the function defines
the maximum generation as a function of voltage on the high side and, optionally, the minimum on the low side.

- `VWCrv`: the high-voltage branch (the V1-P1/V2-P2 pairs), x in percent of `VRef`, y in percent of `WMax` (negative:
  percent of `ChaWMax`, a required consumption). Applies when the voltage is at or above its first vertex.
- `VWCrvLo`: the low-voltage branch (V3-P3/V4-P4), a minimum power; applies at or below its last vertex.
- `VRefOfs`: offset added to the reference, percent of `VRef`.
- `FilTms`: first-order filter time constant on the voltage, seconds.
- Time constants from `rampParams` always apply; its ramp rates only when `UseRmpRte` (BO40).

The attempted output (DVWC.ReqWLim) is the bound in force. Use `volt_watt_curve(V1, P1, V2, P2)` to build a branch
from the standard's pairs.
"""
mutable struct VoltWattMode <: MesaMode
    params::MesaModeParams
    VWCrv::VertexCurve
    VWCrvLo::Union{VertexCurve,Nothing}
    VRefOfs::Float64
    FilTms::Union{Dates.Second,Nothing}
    UseRmpRte::Bool
    rampParams::RampParams
    EcpRef::Symbol
    filteredV::Union{Float64,Nothing}
end

function VoltWattMode(
    params::MesaModeParams;
    VWCrv,
    VWCrvLo = nothing,
    VRefOfs::Real = 0.0,
    FilTms = nothing,
    UseRmpRte::Bool = false,
    rampParams::RampParams = RampParams(),
    EcpRef::Symbol = :default,
)
    VoltWattMode(
        params,
        VWCrv isa VertexCurve ? VWCrv : VertexCurve(VWCrv),
        VWCrvLo === nothing ? nothing : (VWCrvLo isa VertexCurve ? VWCrvLo : VertexCurve(VWCrvLo)),
        Float64(VRefOfs),
        _secn(FilTms),
        UseRmpRte,
        rampParams,
        EcpRef,
        nothing,
    )
end

"A Volt-Watt branch from two voltage/power pairs (percent of VRef, percent of WMax)."
volt_watt_curve(V1::Real, P1::Real, V2::Real, P2::Real) = VertexCurve([(V1, P1), (V2, P2)])

kind(::Type{VoltWattMode}) = Additive()
response_limiting(mode::VoltWattMode) = (true, mode.UseRmpRte)
reset_state!(mode::VoltWattMode) = (mode.filteredV = nothing; nothing)

function modecontrol(
    mode::VoltWattMode,
    ess::EnergyStorageSystem,
    controller::MesaController,
    ::TimeFrameRow,
    useCases::AbstractVector{<:UseCase},
    t::DateTime,
    _,
    ctx::ControlContext,
)
    sig = read_signal(controller, useCases, mode, :V, t)
    sig === nothing && return nothing
    v, VRef = sig
    VRef === nothing && error("VoltWattMode needs a reference voltage (VRef) on its meter or use case")
    vPct = v / VRef * 100
    if mode.FilTms !== nothing && Dates.value(mode.FilTms) > 0
        if mode.filteredV === nothing
            mode.filteredV = vPct
        else
            frac = 1 - exp(-ctx.dt / Dates.value(mode.FilTms))
            mode.filteredV += frac * (vPct - mode.filteredV)
        end
        vPct = mode.filteredV
    end
    vPct -= mode.VRefOfs
    WMax, ChaWMax = p_max(ess), abs(p_min(ess))
    base = ctx.baseKw
    if vPct >= first_x(mode.VWCrv)
        bound = pct_to_kw(evaluate_curve(mode.VWCrv, vPct), WMax, ChaWMax)
        return Delta(min(0.0, bound - base))
    elseif mode.VWCrvLo !== nothing && vPct <= last_x(mode.VWCrvLo)
        bound = pct_to_kw(evaluate_curve(mode.VWCrvLo, vPct), WMax, ChaWMax)
        return Delta(max(0.0, bound - base))
    end
    return abs(previous_WIP(mode)) > 1e-9 ? Delta(0.0) : nothing
end
