"""
Active Power Response functions (IEEE 1815.2 6.4.6; 61850 DWFL1..3): Peak Power Limiting, Load Following and
Generation Following. Three identical, independent parameter groups, each with its own priority, timing, signal
meter, `FolWThr` (power threshold, kW), `FolWPct` (ratio, percent), ramp rates (`RpuRte`/`RpdRte`, Table 23: ramp
rates only) and SOC window. Equation (15): additional output = (reference power − threshold) × `FolWPct` / 100.

- `PeakPowerLimitingMode` is type Bounding: the ESS output must be at least the additional output, so that import at
  the reference point does not exceed the threshold.
- `LoadFollowingMode` is type Additive: discharge by the additional output while the reference load exceeds the
  threshold.
- `GenerationFollowingMode` is type Additive: absorb the generation above the threshold (charge by the additional
  output while the reference generation exceeds the threshold).

Load and Generation Following may coexist when their priorities differ (Table 58, footnote 26); the controller's
additive rule then applies the higher-priority one.
"""

abstract type AbstractFollowingMode <: MesaMode end

# PeakPowerLimitingMode (DWFL1), LoadFollowingMode (DWFL2), GenerationFollowingMode (DWFL3):
#     T(params; FolWThr, FolWPct=100, rampParams=RampParams(), SocUseMinPct, SocUseMaxPct, EcpRef=:default)
for T in (:PeakPowerLimitingMode, :LoadFollowingMode, :GenerationFollowingMode)
    @eval begin
        mutable struct $T <: AbstractFollowingMode
            params::MesaModeParams
            FolWThr::Float64
            FolWPct::Float64
            rampParams::RampParams
            SocUseMinPct::Union{Float64,Nothing}
            SocUseMaxPct::Union{Float64,Nothing}
            EcpRef::Symbol
        end
        $T(
            params::MesaModeParams;
            FolWThr::Real,
            FolWPct::Real = 100.0,
            rampParams::RampParams = RampParams(),
            SocUseMinPct = nothing,
            SocUseMaxPct = nothing,
            EcpRef::Symbol = :default,
        ) = $T(params, Float64(FolWThr), Float64(FolWPct), rampParams, _fl(SocUseMinPct), _fl(SocUseMaxPct), EcpRef)
    end
end

kind(::Type{PeakPowerLimitingMode}) = Bounding()
kind(::Type{LoadFollowingMode}) = Additive()
kind(::Type{GenerationFollowingMode}) = Additive()
response_limiting(::AbstractFollowingMode) = (false, true)

power_sources(::Type{PeakPowerLimitingMode}) = (PeakLimiting, LoadFollowing, GenerationFollowing, VariabilityMitigation)
power_sources(::Type{LoadFollowingMode}) = (LoadFollowing, PeakLimiting, GenerationFollowing, VariabilityMitigation)
power_sources(::Type{GenerationFollowingMode}) = (GenerationFollowing, VariabilityMitigation, PeakLimiting, LoadFollowing)

"Additional output per equation (15), zero when the reference does not exceed the threshold."
additional_output(mode::AbstractFollowingMode, reference::Float64) =
    max(reference - mode.FolWThr, 0.0) * mode.FolWPct / 100

function modecontrol(
    mode::AbstractFollowingMode,
    ess::EnergyStorageSystem,
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
    kw = additional_output(mode, reference)
    mode isa GenerationFollowingMode && (kw = -kw)
    if kw == 0
        return abs(previous_WIP(mode)) > 1e-9 ? (mode isa PeakPowerLimitingMode ? nothing : Delta(0.0)) : nothing
    end
    within_soc_window(ess, kw, mode.SocUseMinPct, mode.SocUseMaxPct) || return nothing
    return mode isa PeakPowerLimitingMode ? Bounds(lo = kw) : Delta(kw)
end
