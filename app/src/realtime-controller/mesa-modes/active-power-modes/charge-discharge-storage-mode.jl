"""
    ChargeDischargeStorageMode(params; WSpt, GnWPctSpt, UseRmpRte=true, rampParams=RampParams())

Charge/Discharge Storage (IEEE 1815.2 6.4.1; 61850 DWGC). Type Replacing.

The target is `WSpt` (kW; the watts target, BI114 = 1) when set, else `GnWPctSpt` as percent of `WMax` when
positive (discharge) or of `ChaWMax` when negative (charge), else the schedule period's power. The last case is the
engine's convention for the "default schedule" of 1815.2 7.2 and also the controller's base when no Replacing mode is
active. `UseRmpRte` selects ramp rates (true, BO38) or time constants (false) from `rampParams`. The storage reserves
`SocUseMinPct`/`SocUseMaxPct` of this function apply to every mode and live on the controller (6.4.1.2).
"""
mutable struct ChargeDischargeStorageMode <: MesaMode
    params::MesaModeParams
    WSpt::Union{Float64,Nothing}
    GnWPctSpt::Union{Float64,Nothing}
    UseRmpRte::Bool
    rampParams::RampParams
end

ChargeDischargeStorageMode(
    params::MesaModeParams;
    WSpt = nothing,
    GnWPctSpt = nothing,
    UseRmpRte::Bool = true,
    rampParams::RampParams = RampParams(),
) = ChargeDischargeStorageMode(params, _fl(WSpt), _fl(GnWPctSpt), UseRmpRte, rampParams)

kind(::Type{ChargeDischargeStorageMode}) = Replacing()
response_limiting(mode::ChargeDischargeStorageMode) = (!mode.UseRmpRte, mode.UseRmpRte)

function modecontrol(
    mode::ChargeDischargeStorageMode,
    ess::EnergyStorageSystem,
    ::MesaController,
    schedulePeriod::TimeFrameRow,
    ::AbstractVector{<:UseCase},
    ::DateTime,
    _,
    ::ControlContext,
)
    target = if mode.WSpt !== nothing
        mode.WSpt
    elseif mode.GnWPctSpt !== nothing
        pct_to_kw(mode.GnWPctSpt, p_max(ess), abs(p_min(ess)))
    else
        average_power(schedulePeriod)
    end
    return Setpoint(target)
end
