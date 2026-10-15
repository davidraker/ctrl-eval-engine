"""
    ActivePowerLimitMode(params; LimWMax, LimWMin, LimWMaxKw, LimWMinKw, EcpRef=:default)

Active Power Limiting (IEEE 1815.2 6.4.2; 61850 DWMX for the maximum, DWMN for the minimum). Type Bounding.

`LimWMax` (DWMX.LimW) and `LimWMin` (DWMN.LimW) are percent: of `WMax` when positive, of `ChaWMax` when negative,
following 6.4.1's sign convention (the equations in 6.4.2 appear transposed and are not copied). `LimWMaxKw` and
`LimWMinKw` are the watts alternatives (BO45) and take precedence. The interval [min, max] is applied to the final
output regardless of priority: a positive maximum is a generation cap, a negative maximum a minimum consumption, a
positive minimum a minimum generation, a negative minimum a consumption cap. Only the device maximum ramp rates apply.
The reference point is the ESS terminals until a site model exists (`EcpRef` is recorded only).
"""
mutable struct ActivePowerLimitMode <: MesaMode
    params::MesaModeParams
    LimWMax::Union{Float64,Nothing}
    LimWMin::Union{Float64,Nothing}
    LimWMaxKw::Union{Float64,Nothing}
    LimWMinKw::Union{Float64,Nothing}
    EcpRef::Symbol
end

function ActivePowerLimitMode(
    params::MesaModeParams;
    LimWMax = nothing,
    LimWMin = nothing,
    LimWMaxKw = nothing,
    LimWMinKw = nothing,
    EcpRef::Symbol = :default,
)
    mode = ActivePowerLimitMode(params, _fl(LimWMax), _fl(LimWMin), _fl(LimWMaxKw), _fl(LimWMinKw), EcpRef)
    if mode.LimWMaxKw !== nothing && mode.LimWMinKw !== nothing && mode.LimWMaxKw < mode.LimWMinKw
        throw(
            ArgumentError(
                "Active Power Limit: maximum ($(mode.LimWMaxKw) kW) must be ≥ minimum ($(mode.LimWMinKw) kW)",
            ),
        )
    elseif mode.LimWMaxKw === nothing &&
           mode.LimWMinKw === nothing &&
           mode.LimWMax !== nothing &&
           mode.LimWMin !== nothing &&
           mode.LimWMax < mode.LimWMin
        throw(
            ArgumentError("Active Power Limit: maximum ($(mode.LimWMax) %) must be ≥ minimum ($(mode.LimWMin) %)"),
        )
    end
    return mode
end

kind(::Type{ActivePowerLimitMode}) = Bounding()

function limit_interval(mode::ActivePowerLimitMode, ess::EnergyStorageSystem)
    WMax, ChaWMax = p_max(ess), abs(p_min(ess))
    hi =
        mode.LimWMaxKw !== nothing ? mode.LimWMaxKw :
        mode.LimWMax !== nothing ? pct_to_kw(mode.LimWMax, WMax, ChaWMax) : Inf
    lo =
        mode.LimWMinKw !== nothing ? mode.LimWMinKw :
        mode.LimWMin !== nothing ? pct_to_kw(mode.LimWMin, WMax, ChaWMax) : -Inf
    return lo, hi
end

function modecontrol(
    mode::ActivePowerLimitMode,
    ess::EnergyStorageSystem,
    ::MesaController,
    ::TimeFrameRow,
    ::AbstractVector{<:UseCase},
    ::DateTime,
    _,
    ::ControlContext,
)
    lo, hi = limit_interval(mode, ess)
    (isinf(lo) && isinf(hi)) && return nothing
    return Bounds(lo, hi)
end
