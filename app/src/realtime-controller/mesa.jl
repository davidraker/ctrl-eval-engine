"""
MESA / IEEE 1815.2 real-time controller.

A `MesaController` combines a set of `MesaMode`s, each implementing one of the active power functions of
IEEE Std 1815.2-2025 (the DNP3 DER profile, which carries the MESA-ESS functions), into one active power command
for an energy storage system. Field names follow the IEC 61850-7-420 data objects that IEEE 1815.2 maps its points
to (`ModEna`, `ModPrio`, `WinTms`, `RmpTms`, `RvrtTms`, `RpuRte`, `GnWPctSpt`, `LimW`, ...), so a configuration keyed
by those names maps onto a mode field by field. Engineering units are used throughout: kW, percent, percent per
second, Hz, seconds.

Combination follows clause 7.3 (Table 58): a mode is *Replacing* (sets the base power), *Additive* (adds to it) or
*Bounding* (clamps the result). See `control` for the pipeline and `mesa-modes/README.md` for the rules.
"""

using Dates
using Random
using CtrlEvalEngine.EnergyStorageSimulators
using CtrlEvalEngine.EnergyStorageUseCases:
    UseCase,
    FrequencyResponse,
    VoltageControl,
    PeakLimiting,
    LoadFollowing,
    GenerationFollowing,
    VariabilityMitigation,
    Regulation
using CtrlEvalEngine.EnergyStorageScheduling: average_power, regulation_capacity

abstract type MesaMode end

# ------------------------------------------------------------------------------------------------------------------
# Mode kinds (IEEE 1815.2-2025 clause 7.3, Table 58)
# ------------------------------------------------------------------------------------------------------------------

abstract type ModeKind end
"Sets the base active power; the highest-priority active one wins (Charge/Discharge, AGC, Coordinated C/D)."
struct Replacing <: ModeKind end
"Adds to the base; all additions of the best priority group apply, lower groups are suppressed."
struct Additive <: ModeKind end
"Clamps the result regardless of priority (Active Power Limit, Peak Power Limiting)."
struct Bounding <: ModeKind end

kind(mode::MesaMode) = kind(typeof(mode))

"""
    mutually_exclusive(::Type{A}, ::Type{B})

True when Table 58 marks the two functions mutually exclusive (Ex). Checked in one direction; `conflicts`
checks both. Modes extend this with methods on their own type.
"""
mutually_exclusive(::Type{<:MesaMode}, ::Type{<:MesaMode}) = false
conflicts(a::MesaMode, b::MesaMode) =
    mutually_exclusive(typeof(a), typeof(b)) || mutually_exclusive(typeof(b), typeof(a))

struct ModeConflictError <: Exception
    msg::String
end
Base.showerror(io::IO, e::ModeConflictError) = print(io, "ModeConflictError: ", e.msg)

# ------------------------------------------------------------------------------------------------------------------
# Shared parameters (61850 common mode data objects; IEEE 1815.2 6.1.2 enabling timing parameters)
# ------------------------------------------------------------------------------------------------------------------

_sec(::Nothing) = Dates.Second(0)
_sec(p::Dates.Period) = Dates.Second(p)
_sec(x::Real) = Dates.Second(round(Int, x))
_secn(::Nothing) = nothing
_secn(x) = _sec(x)
_fl(::Nothing) = nothing
_fl(x::Real) = Float64(x)

"""
    MesaModeParams(ModPrio; ModEna=true, WinTms=0, RmpTms=0, RvrtTms=0)

Parameters every MESA function shares, plus the run-time state the controller keeps per mode.

- `ModPrio`: priority, zero is the highest (1815.2 7.1).
- `ModEna`: enabled. An enabled mode monitors its inputs; it is *active* when it affects the output (7.3).
- `WinTms`: Enabling Time Window. The function starts at a random moment inside the window after the enable
  (6.1.2); zero means immediately. The controller draws the moment from its RNG, or uses the end of the window when
  it has none.
- `RmpTms`: Enabling Ramp Time over which the function's contribution moves from the current output to the new.
- `RvrtTms`: Reversion Timeout after which the function disables itself, counted from the start; zero never.
"""
mutable struct MesaModeParams
    ModPrio::Int
    ModEna::Bool
    WinTms::Dates.Second
    RmpTms::Dates.Second
    RvrtTms::Dates.Second
    # run-time state
    enabledAt::Union{DateTime,Nothing}
    startAt::Union{DateTime,Nothing}
    startKw::Union{Float64,Nothing}   # the ESS power when the function started, origin of the enabling ramp
    activeSince::Union{DateTime,Nothing}
    attempted::Float64
    modeWIP::Union{FixedIntervalTimeSeries,Nothing}
end

MesaModeParams(
    ModPrio::Integer;
    ModEna::Bool = true,
    WinTms = Dates.Second(0),
    RmpTms = Dates.Second(0),
    RvrtTms = Dates.Second(0),
) = MesaModeParams(
    Int(ModPrio),
    ModEna,
    _sec(WinTms),
    _sec(RmpTms),
    _sec(RvrtTms),
    nothing,
    nothing,
    nothing,
    nothing,
    0.0,
    nothing,
)

MesaModeParams(ModPrio::Integer, WinTms, RmpTms, RvrtTms) =
    MesaModeParams(ModPrio; WinTms = WinTms, RmpTms = RmpTms, RvrtTms = RvrtTms)

priority(mode::MesaMode) = mode.params.ModPrio
is_enabled(mode::MesaMode) = mode.params.ModEna
is_active(mode::MesaMode) = mode.params.activeSince !== nothing

"The mode's contribution on the previous tick (kW; for Bounding modes the bound it attempted)."
function previous_WIP(mode::MesaMode)
    mode.params.modeWIP === nothing && return 0.0
    wip = raw_vector(mode.params.modeWIP)
    return isempty(wip) ? 0.0 : Float64(wip[end])
end

# ------------------------------------------------------------------------------------------------------------------
# Response limiting parameters (IEEE 1815.2 6.1.5, 6.1.6; Tables 22 and 23)
# ------------------------------------------------------------------------------------------------------------------

"""
    RampParams(; RpuRte, RpdRte, RpuChaRte, RpdChaRte, RmpUpTms, RmpDnTms)
    RampParams(RpuRte, RpdRte, RpuChaRte, RpdChaRte)
    RampParams(RmpUpTms::Period, RmpDnTms::Period)

Ramp rates and time constants of one function. Ramp rates are percent per second: `RpuRte`/`RpdRte` of `WMax`
(discharging up/down), `RpuChaRte`/`RpdChaRte` of `ChaWMax` (charging up/down). Time constants `RmpUpTms`/`RmpDnTms`
are interpreted per the controller's `OpnLoopTau` setting. `nothing` means unlimited / not used.
"""
struct RampParams
    RpuRte::Union{Float64,Nothing}
    RpdRte::Union{Float64,Nothing}
    RpuChaRte::Union{Float64,Nothing}
    RpdChaRte::Union{Float64,Nothing}
    RmpUpTms::Union{Dates.Second,Nothing}
    RmpDnTms::Union{Dates.Second,Nothing}
end

RampParams(;
    RpuRte = nothing,
    RpdRte = nothing,
    RpuChaRte = nothing,
    RpdChaRte = nothing,
    RmpUpTms = nothing,
    RmpDnTms = nothing,
) = RampParams(_fl(RpuRte), _fl(RpdRte), _fl(RpuChaRte), _fl(RpdChaRte), _secn(RmpUpTms), _secn(RmpDnTms))

RampParams(RpuRte::Real, RpdRte::Real, RpuChaRte::Real, RpdChaRte::Real) =
    RampParams(; RpuRte, RpdRte, RpuChaRte, RpdChaRte)
RampParams(RmpUpTms::Dates.Period, RmpDnTms::Dates.Period) = RampParams(; RmpUpTms, RmpDnTms)

has_rates(rp::RampParams) = any(!isnothing, (rp.RpuRte, rp.RpdRte, rp.RpuChaRte, rp.RpdChaRte))
has_time_constants(rp::RampParams) = rp.RmpUpTms !== nothing || rp.RmpDnTms !== nothing

# ------------------------------------------------------------------------------------------------------------------
# Measurement inputs (the standard's "signal meter" at the reference point of applicability)
# ------------------------------------------------------------------------------------------------------------------

"""
    MeterReadings(; W, V, Hz, VRef, HzNom=60.0)

Measurements at one reference point. Each quantity is a `TimeSeries` (simulation) or a number (the latest live
reading, see `set_reading!`). `VRef` is the nominal voltage in the same unit as `V`; `HzNom` the nominal frequency.
"""
mutable struct MeterReadings
    W::Union{TimeSeries,Real,Nothing}
    V::Union{TimeSeries,Real,Nothing}
    Hz::Union{TimeSeries,Real,Nothing}
    VRef::Union{Float64,Nothing}
    HzNom::Float64
end

MeterReadings(; W = nothing, V = nothing, Hz = nothing, VRef = nothing, HzNom = 60.0) =
    MeterReadings(W, V, Hz, _fl(VRef), Float64(HzNom))

set_reading!(m::MeterReadings, quantity::Symbol, value::Real) = setfield!(m, quantity, value)

_sample(ts::TimeSeries, t::DateTime) = Float64(get_period(ts, t)[1])
_sample(x::Real, ::DateTime) = Float64(x)

"The use cases a mode may read a power signal from, in order of preference, when no meter is configured."
power_sources(::Type{<:MesaMode}) = (PeakLimiting, LoadFollowing, GenerationFollowing, VariabilityMitigation)
power_signal(uc::PeakLimiting) = uc.realtimePower
power_signal(uc::LoadFollowing) = uc.realtimeLoadPower
power_signal(uc::GenerationFollowing) = uc.realtimePower
power_signal(uc::VariabilityMitigation) = uc.pvGenProfile

"The meter a mode reads (its `EcpRef`), `:default` when the mode has none."
ecp_ref(mode::MesaMode) = hasfield(typeof(mode), :EcpRef) ? getfield(mode, :EcpRef) : :default

# ------------------------------------------------------------------------------------------------------------------
# Controller, status and mode outputs
# ------------------------------------------------------------------------------------------------------------------

"""
    MesaStatus

What the controller did on its last tick, for status read-back (the attempted-output and "active" points of
1815.2). Vectors are aligned with `controller.modes`.
"""
mutable struct MesaStatus
    t::Union{DateTime,Nothing}
    outputKw::Float64
    baseKw::Float64
    baseMode::Union{Int,Nothing}
    enabled::Vector{Bool}
    active::Vector{Bool}
    suppressed::Vector{Bool}
    attempted::Vector{Float64}
    boundLo::Float64
    boundHi::Float64
    boundBinding::Bool
    reserveBinding::Bool
    rampBinding::Bool
    deviceBinding::Bool
    extras::Dict{Int,Dict{Symbol,Float64}}
end

MesaStatus(n::Integer) = MesaStatus(
    nothing,
    0.0,
    0.0,
    nothing,
    falses(n),
    falses(n),
    falses(n),
    zeros(n),
    -Inf,
    Inf,
    false,
    false,
    false,
    false,
    Dict{Int,Dict{Symbol,Float64}}(),
)

"""
    MesaController(modes, resolution; kwargs...)

- `maxRampRates::RampParams`: the device maximum ramp rates (DCTE `RpuRteMax`, `RpdRteMax`, `RpuChaRteMax`,
  `RpdChaRteMax`), applied to the final output after every function's own limiting.
- `SocUseMinPct`, `SocUseMaxPct`: storage-wide reserves (DWGC, 6.4.1.2: "also apply in any other modes that involve
  charging and discharging"), percent of usable energy.
- `OpnLoopTau`: how time constants are read (DGEN.OpnLoopTau). `true`: an open-loop response time to reach `OplPct`
  of the change; `false`: the 95 % settling time (3 τ) of a first-order filter.
- `randomSeed`: seeds the RNG that draws the start inside each enabling time window; `nothing` starts deterministically
  at the end of the window.
- `meters`: `Dict{Symbol,MeterReadings}` keyed by the `EcpRef` names modes refer to.
"""
mutable struct MesaController <: RTController
    modes::Vector{MesaMode}
    resolution::Dates.Period
    wip::Union{FixedIntervalTimeSeries,Nothing}
    maxRampRates::RampParams
    SocUseMinPct::Float64
    SocUseMaxPct::Float64
    OpnLoopTau::Bool
    OplPct::Float64
    rng::Union{AbstractRNG,Nothing}
    meters::Dict{Symbol,MeterReadings}
    lastBase::Union{Float64,Nothing}
    status::MesaStatus
end

function MesaController(
    modes::AbstractVector,
    resolution::Dates.Period;
    maxRampRates::RampParams = RampParams(),
    SocUseMinPct::Real = 0.0,
    SocUseMaxPct::Real = 100.0,
    OpnLoopTau::Bool = true,
    OplPct::Real = 90.0,
    randomSeed::Union{Integer,Nothing} = nothing,
    meters::AbstractDict = Dict{Symbol,MeterReadings}(),
)
    modeVec = MesaMode[modes...]
    controller = MesaController(
        modeVec,
        resolution,
        nothing,
        maxRampRates,
        Float64(SocUseMinPct),
        Float64(SocUseMaxPct),
        OpnLoopTau,
        Float64(OplPct),
        randomSeed === nothing ? nothing : MersenneTwister(randomSeed),
        Dict{Symbol,MeterReadings}(meters),
        nothing,
        MesaStatus(length(modeVec)),
    )
    check_compatibility(controller)
    return controller
end

"Throw `ModeConflictError` if two enabled modes are mutually exclusive (Table 58)."
function check_compatibility(controller::MesaController)
    enabled = filter(is_enabled, controller.modes)
    for i in eachindex(enabled), j in i+1:length(enabled)
        if conflicts(enabled[i], enabled[j])
            throw(
                ModeConflictError(
                    "$(nameof(typeof(enabled[i]))) and $(nameof(typeof(enabled[j]))) are mutually exclusive",
                ),
            )
        end
    end
end

"""
    enable!(controller, mode, t)

Enable `mode` at time `t`: rejected with `ModeConflictError` (the standard's PARAMETER_ERROR) when a mutually
exclusive mode is already enabled. Starts the enabling time window, ramp time and reversion timeout.
"""
function enable!(controller::MesaController, mode::MesaMode, t::DateTime)
    for other in controller.modes
        if other !== mode && is_enabled(other) && conflicts(mode, other)
            throw(
                ModeConflictError(
                    "cannot enable $(nameof(typeof(mode))): $(nameof(typeof(other))) is enabled and mutually exclusive",
                ),
            )
        end
    end
    p = mode.params
    p.ModEna = true
    p.enabledAt = t
    delay =
        if Dates.value(p.WinTms) <= 0
            0
        elseif controller.rng === nothing
            Dates.value(p.WinTms)
        else
            rand(controller.rng, 0:Dates.value(p.WinTms))
        end
    p.startAt = t + Dates.Second(delay)
    p.startKw = nothing
    p.activeSince = nothing
    return mode
end
enable!(controller::MesaController, idx::Integer, t::DateTime) = enable!(controller, controller.modes[idx], t)

"Disable `mode` and clear its activation state."
function disable!(::MesaController, mode::MesaMode)
    p = mode.params
    p.ModEna = false
    p.enabledAt = nothing
    p.startAt = nothing
    p.startKw = nothing
    p.activeSince = nothing
    p.attempted = 0.0
    reset_state!(mode)
    return mode
end
disable!(controller::MesaController, idx::Integer) = disable!(controller, controller.modes[idx])

"Hook for modes with internal state (timers, snapshots, filters) to clear it on disable."
reset_state!(::MesaMode) = nothing

"Hook for modes to report extra status quantities (AGC's watts available, predicted SOC, ...)."
status_extras(::MesaMode, ::EnergyStorageSystem, ctx) = nothing

"What a mode wants on this tick. `nothing` from `modecontrol` means the mode is enabled but inactive."
abstract type ModeOutput end
"An absolute active power target (kW) from a Replacing mode."
struct Setpoint <: ModeOutput
    kw::Float64
end
"A change (kW) relative to the base from an Additive mode."
struct Delta <: ModeOutput
    kw::Float64
end
"An interval [lo, hi] (kW) the output must stay inside, from a Bounding mode."
struct Bounds <: ModeOutput
    lo::Float64
    hi::Float64
end
Bounds(; lo = -Inf, hi = Inf) = Bounds(Float64(lo), Float64(hi))

"Per-tick context handed to `modecontrol`."
struct ControlContext
    dt::Float64                      # step length, seconds
    actualKw::Float64                # the ESS's actual power entering this tick
    baseKw::Union{Float64,Nothing}   # the base once chosen (Additive and Bounding stages)
end

"""
    modecontrol(mode, ess, controller, schedulePeriod, useCases, t, spProgress, ctx) -> ModeOutput or nothing

Each mode's control law. Return a `Setpoint`, `Delta` or `Bounds` matching `kind(mode)`, or `nothing` when the mode
has nothing to contribute (no input, deadband, outside its SOC window). Response limiting is applied by the
controller; the mode returns the unlimited value.
"""
function modecontrol end

"Which response limiting Table 23 gives the function: `(useTau, useRates)`. Default: whatever the params carry."
response_limiting(mode::MesaMode) =
    hasfield(typeof(mode), :rampParams) ? (true, true) : (false, false)
ramp_params(mode::MesaMode) = hasfield(typeof(mode), :rampParams) ? mode.rampParams : RampParams()

# ------------------------------------------------------------------------------------------------------------------
# Signals
# ------------------------------------------------------------------------------------------------------------------

"""
    read_signal(controller, useCases, mode, quantity, t) -> (value, reference) or nothing

Read `:W`, `:V` or `:Hz` for `mode` at `t`: from the meter named by the mode's `EcpRef` when the controller has one
with that quantity, otherwise from the use cases (`FrequencyResponse`, `VoltageControl`, the power-carrying use cases
in `power_sources` order). `reference` is `HzNom` for frequency, `VRef` for voltage, `nothing` for power.
"""
function read_signal(
    controller::MesaController,
    useCases::AbstractVector{<:UseCase},
    mode::MesaMode,
    quantity::Symbol,
    t::DateTime,
)
    meter = get(controller.meters, ecp_ref(mode), nothing)
    if meter !== nothing && getfield(meter, quantity) !== nothing
        value = _sample(getfield(meter, quantity), t)
        ref = quantity === :Hz ? meter.HzNom : quantity === :V ? meter.VRef : nothing
        return (value, ref)
    end
    if quantity === :Hz
        idx = findfirst(uc -> uc isa FrequencyResponse, useCases)
        idx === nothing && return nothing
        uc = useCases[idx]
        return (_sample(uc.meteredFrequency, t), Float64(uc.nominalFrequency))
    elseif quantity === :V
        idx = findfirst(uc -> uc isa VoltageControl, useCases)
        idx === nothing && return nothing
        uc = useCases[idx]
        return (_sample(uc.meteredVoltage, t), Float64(uc.referenceVoltage))
    elseif quantity === :W
        for T in power_sources(typeof(mode))
            idx = findfirst(uc -> uc isa T, useCases)
            idx === nothing && continue
            return (_sample(power_signal(useCases[idx]), t), nothing)
        end
        return nothing
    end
    error("unknown signal quantity $quantity")
end

# ------------------------------------------------------------------------------------------------------------------
# Response limiting (IEEE 1815.2 6.1.5 time constants, 6.1.6 ramp rates)
# ------------------------------------------------------------------------------------------------------------------

"""
    apply_time_constant(controller, current, target, dt, tau)

Move `current` toward `target` over a step of `dt` seconds with time constant `tau`. With `OpnLoopTau` the
constant is the open-loop response time to reach `OplPct` percent of the change; otherwise it is the 95 % settling
time (three time constants) of a first-order low-pass filter.
"""
function apply_time_constant(controller::MesaController, current::Float64, target::Float64, dt::Float64, tau)
    tau === nothing && return target
    τ = Float64(Dates.value(Dates.Second(tau)))
    (τ <= 0 || dt <= 0) && return target
    frac = if controller.OpnLoopTau
        1 - (1 - controller.OplPct / 100)^(dt / τ)
    else
        1 - exp(-dt / (τ / 3))
    end
    return current + frac * (target - current)
end

"""
    ramp_toward(current, target, dt, rp, WMax, ChaWMax)

Move `current` toward `target` over `dt` seconds limited by the ramp rates in `rp` (percent per second of `WMax`
when discharging, of `ChaWMax` when charging). A change crossing zero uses the discharging rate down to zero and
the charging rate beyond it (or vice versa), each for its share of the step.
"""
function ramp_toward(current::Float64, target::Float64, dt::Float64, rp::RampParams, WMax::Float64, ChaWMax::Float64)
    p = current
    remaining = dt
    for _ = 1:4
        (p == target || remaining <= 0) && break
        if p >= 0 && target > p            # more discharge
            rate, ref, segTarget = rp.RpuRte, WMax, target
        elseif p > 0 && target < p         # less discharge, stop at zero
            rate, ref, segTarget = rp.RpdRte, WMax, max(target, 0.0)
        elseif p <= 0 && target < p        # more charge
            rate, ref, segTarget = rp.RpuChaRte, ChaWMax, target
        else                               # p < 0 && target > p: less charge, stop at zero
            rate, ref, segTarget = rp.RpdChaRte, ChaWMax, min(target, 0.0)
        end
        if rate === nothing
            p = segTarget
            continue
        end
        kwPerSec = rate / 100 * ref
        kwPerSec <= 0 && break
        need = abs(segTarget - p)
        can = kwPerSec * remaining
        if can >= need
            p = segTarget
            remaining -= need / kwPerSec
        else
            p += sign(segTarget - p) * can
            remaining = 0.0
        end
    end
    return p
end

"""
    limit_response(controller, ess, rp, current, target, dt; useTau=true, useRates=true)

Table 22 order for one function: time constant first, then the function's ramp rates. Device maximum ramp rates
are applied by the controller on the final output.
"""
function limit_response(
    controller::MesaController,
    ess::EnergyStorageSystem,
    rp::RampParams,
    current::Float64,
    target::Float64,
    dt::Float64;
    useTau::Bool = true,
    useRates::Bool = true,
)
    p = target
    if useTau && has_time_constants(rp)
        tau = target >= current ? rp.RmpUpTms : rp.RmpDnTms
        p = apply_time_constant(controller, current, target, dt, tau)
    end
    if useRates && has_rates(rp)
        p = ramp_toward(current, p, dt, rp, p_max(ess), abs(p_min(ess)))
    end
    return p
end

# ------------------------------------------------------------------------------------------------------------------
# Energy and SOC limits
# ------------------------------------------------------------------------------------------------------------------

"""
    apply_energy_limits(ess, power, duration, minReservePct=nothing, maxReservePct=nothing)

Limit `power` (kW) over `duration` so the stored energy stays inside the reserve window, given as percent of usable
capacity (`e_max`), or inside the physical window when no reserves are given.
"""
function apply_energy_limits(
    ess::EnergyStorageSystem,
    power::Float64,
    duration::Dates.Period,
    minReserve::Union{Real,Nothing} = nothing,
    maxReserve::Union{Real,Nothing} = nothing,
)
    minEnergy = minReserve === nothing ? e_min(ess) : minReserve / 100 * e_max(ess)
    maxEnergy = maxReserve === nothing ? e_max(ess) : maxReserve / 100 * e_max(ess)
    hours = duration / Hour(1)
    hours <= 0 && return power
    stored = energy_state(ess)
    proposed = stored - power * hours          # positive power discharges
    if power > 0 && proposed < minEnergy
        return min(power, max((stored - minEnergy) / hours, 0.0))
    elseif power < 0 && proposed > maxEnergy
        return max(power, min((stored - maxEnergy) / hours, 0.0))
    else
        return power
    end
end

"""
    within_soc_window(ess, kw, SocUseMinPct, SocUseMaxPct)

A function's own usable-SOC window: discharging is not allowed at or below `SocUseMinPct`, charging not at or above
`SocUseMaxPct` (percent of usable capacity). `nothing` disables a side.
"""
function within_soc_window(ess::EnergyStorageSystem, kw::Float64, minPct, maxPct)
    socPct = SOC(ess) * 100
    kw > 0 && minPct !== nothing && socPct <= minPct && return false
    kw < 0 && maxPct !== nothing && socPct >= maxPct && return false
    return true
end

# ------------------------------------------------------------------------------------------------------------------
# The control pipeline
# ------------------------------------------------------------------------------------------------------------------

"The ESS's actual power entering this tick: the schedule-period progress, else the controller's last output."
function actual_power(controller::MesaController, spProgress)
    if spProgress !== nothing && !isempty(raw_vector(spProgress))
        return Float64(last(raw_vector(spProgress)))
    elseif controller.wip !== nothing && !isempty(raw_vector(controller.wip))
        return Float64(last(raw_vector(controller.wip)))
    else
        return 0.0
    end
end

"Fraction of the enabling ramp time elapsed, 1.0 when none is configured."
function enabling_fraction(p::MesaModeParams, t::DateTime)
    Dates.value(p.RmpTms) <= 0 && return 1.0
    p.startAt === nothing && return 1.0
    return clamp((t - p.startAt) / p.RmpTms, 0.0, 1.0)
end

function _housekeeping!(controller::MesaController, t::DateTime)
    for mode in controller.modes
        p = mode.params
        if p.ModEna && p.enabledAt === nothing
            enable!(controller, mode, t)   # enabled at construction: the first tick is the enable time
        end
        if p.ModEna &&
           Dates.value(p.RvrtTms) > 0 &&
           p.startAt !== nothing &&
           t >= p.startAt + p.RvrtTms
            disable!(controller, mode)
        end
    end
end

"A mode may run when enabled and its enabling time window has elapsed; records the power it starts from."
function may_run(p::MesaModeParams, t::DateTime, actualKw::Float64)
    ok = p.ModEna && p.startAt !== nothing && t >= p.startAt
    ok && p.startKw === nothing && (p.startKw = actualKw)
    return ok
end

"Blend `target` from the power the function started at over its enabling ramp time."
enabling_blend(p::MesaModeParams, t::DateTime, target::Float64) = begin
    frac = enabling_fraction(p, t)
    frac >= 1 && return target
    origin = p.startKw === nothing ? 0.0 : p.startKw
    origin + frac * (target - origin)
end

function _record_wip!(ts::Union{FixedIntervalTimeSeries,Nothing}, t::DateTime, resolution, value::Float64)
    if ts === nothing
        return FixedIntervalTimeSeries(t, resolution, [value])
    else
        push!(raw_vector(ts), value)
        return ts
    end
end

function control(
    ess::EnergyStorageSystem,
    controller::MesaController,
    schedulePeriod::TimeFrameRow,
    useCases::AbstractVector{<:UseCase},
    t::Dates.DateTime,
    spProgress,
)
    n = length(controller.modes)
    status = controller.status
    if length(status.enabled) != n
        controller.status = status = MesaStatus(n)
    end
    dt = controller.resolution / Dates.Second(1)
    duration = Dates.Millisecond(controller.resolution)

    # 1. Housekeeping: enable on first sight, expire on reversion timeout.
    _housekeeping!(controller, t)
    actualKw = actual_power(controller, spProgress)
    WMax = p_max(ess)
    ChaWMax = abs(p_min(ess))

    fill!(status.active, false)
    fill!(status.suppressed, false)
    fill!(status.attempted, 0.0)
    empty!(status.extras)
    contributions = zeros(n)
    order = sortperm([priority(m) for m in controller.modes])   # do not mutate the caller's order

    # 2./3. Base: the highest-priority active Replacing mode, ties to the most recently activated.
    ctx = ControlContext(dt, actualKw, nothing)
    baseKw = average_power(schedulePeriod)
    baseMode = nothing
    bestKey = nothing
    for i in order
        mode = controller.modes[i]
        kind(mode) isa Replacing || continue
        p = mode.params
        may_run(p, t, actualKw) || (p.activeSince = nothing; continue)
        out = modecontrol(mode, ess, controller, schedulePeriod, useCases, t, spProgress, ctx)
        if out === nothing
            p.activeSince = nothing
            continue
        end
        out isa Setpoint || error("$(nameof(typeof(mode))) is a Replacing mode and must return a Setpoint")
        p.activeSince === nothing && (p.activeSince = t)
        status.active[i] = true
        p.attempted = out.kw
        status.attempted[i] = out.kw
        key = (priority(mode), -Dates.datetime2epochms(p.activeSince))
        if bestKey === nothing || key < bestKey
            bestKey = key
            baseMode = i
        end
    end
    if baseMode !== nothing
        mode = controller.modes[baseMode]
        p = mode.params
        target = enabling_blend(p, t, p.attempted)
        useTau, useRates = response_limiting(mode)
        baseKw = limit_response(controller, ess, ramp_params(mode), actualKw, target, dt; useTau, useRates)
        contributions[baseMode] = baseKw
        for i in order
            i == baseMode && continue
            kind(controller.modes[i]) isa Replacing && status.active[i] && (status.suppressed[i] = true)
        end
    end
    controller.lastBase = baseKw
    status.baseKw = baseKw
    status.baseMode = baseMode

    # 4. Additions: the best priority group among active Additive modes applies; the rest are suppressed.
    ctx = ControlContext(dt, actualKw, baseKw)
    bestAdditive = nothing
    additive = Int[]
    for i in order
        mode = controller.modes[i]
        kind(mode) isa Additive || continue
        p = mode.params
        may_run(p, t, actualKw) || (p.activeSince = nothing; continue)
        out = modecontrol(mode, ess, controller, schedulePeriod, useCases, t, spProgress, ctx)
        if out === nothing
            p.activeSince = nothing
            continue
        end
        out isa Delta || error("$(nameof(typeof(mode))) is an Additive mode and must return a Delta")
        p.activeSince === nothing && (p.activeSince = t)
        status.active[i] = true
        delta = out.kw * enabling_fraction(p, t)
        useTau, useRates = response_limiting(mode)
        delta = limit_response(controller, ess, ramp_params(mode), previous_WIP(mode), delta, dt; useTau, useRates)
        p.attempted = delta
        status.attempted[i] = delta
        push!(additive, i)
        if bestAdditive === nothing || priority(mode) < bestAdditive
            bestAdditive = priority(mode)
        end
    end
    powerKw = baseKw
    for i in additive
        if priority(controller.modes[i]) == bestAdditive
            contributions[i] = status.attempted[i]
            powerKw += contributions[i]
        else
            status.suppressed[i] = true
        end
    end

    # 5. Bounds: intersect every active Bounding mode's interval and clamp, regardless of priority.
    lo, hi = -Inf, Inf
    for i in order
        mode = controller.modes[i]
        kind(mode) isa Bounding || continue
        p = mode.params
        may_run(p, t, actualKw) || (p.activeSince = nothing; continue)
        out = modecontrol(mode, ess, controller, schedulePeriod, useCases, t, spProgress, ctx)
        if out === nothing
            p.activeSince = nothing
            continue
        end
        out isa Bounds || error("$(nameof(typeof(mode))) is a Bounding mode and must return Bounds")
        p.activeSince === nothing && (p.activeSince = t)
        status.active[i] = true
        bLo, bHi = out.lo, out.hi
        useTau, useRates = response_limiting(mode)
        if isfinite(bLo)
            bLo = enabling_blend(p, t, bLo)
            bLo = limit_response(controller, ess, ramp_params(mode), previous_WIP(mode), bLo, dt; useTau, useRates)
        end
        if isfinite(bHi)
            bHi = enabling_blend(p, t, bHi)
            bHi = limit_response(controller, ess, ramp_params(mode), previous_WIP(mode), bHi, dt; useTau, useRates)
        end
        attempted = isfinite(bHi) ? bHi : bLo
        p.attempted = attempted
        status.attempted[i] = attempted
        contributions[i] = attempted
        lo = max(lo, bLo)
        hi = min(hi, bHi)
    end
    if lo > hi
        # Conflicting bounds: the standard requires maximum ≥ minimum; the tighter upper bound wins.
        lo = hi
    end
    status.boundLo, status.boundHi = lo, hi
    bounded = clamp(powerKw, lo, hi)
    status.boundBinding = bounded != powerKw
    powerKw = bounded

    # 6. Storage-wide reserves.
    reserved = apply_energy_limits(ess, powerKw, duration, controller.SocUseMinPct, controller.SocUseMaxPct)
    status.reserveBinding = reserved != powerKw
    powerKw = reserved

    # 7. Device maximum ramp rates against the actual power.
    ramped = has_rates(controller.maxRampRates) ?
        ramp_toward(actualKw, powerKw, dt, controller.maxRampRates, WMax, ChaWMax) : powerKw
    status.rampBinding = ramped != powerKw
    powerKw = ramped

    # 8. Device limits and energy feasibility.
    limited = clamp(powerKw, p_min(ess, duration), p_max(ess, duration))
    limited = apply_energy_limits(ess, limited, duration)
    status.deviceBinding = limited != powerKw
    powerKw = limited

    # 9. Record.
    for (i, mode) in enumerate(controller.modes)
        status.enabled[i] = is_enabled(mode)
        mode.params.modeWIP = _record_wip!(mode.params.modeWIP, t, controller.resolution, contributions[i])
        extras = status_extras(mode, ess, ctx)
        extras === nothing || (status.extras[i] = extras)
    end
    controller.wip = _record_wip!(controller.wip, t, controller.resolution, powerKw)
    status.t = t
    status.outputKw = powerKw
    return FixedIntervalTimeSeries(t, controller.resolution, [powerKw])
end

"The controller's status after its last tick."
mesa_status(controller::MesaController) = controller.status

include("mesa-modes/curve-utils.jl")
include("mesa-modes/active-power-modes/charge-discharge-storage-mode.jl")
include("mesa-modes/active-power-modes/active-power-limit-mode.jl")
include("mesa-modes/active-power-modes/agc-mode.jl")
include("mesa-modes/active-power-modes/coordinated-charge-discharge-mode.jl")
include("mesa-modes/active-power-modes/frequency-watt-modes.jl")
include("mesa-modes/active-power-modes/volt-watt-mode.jl")
include("mesa-modes/active-power-modes/dynamic-volt-watt-mode.jl")
include("mesa-modes/active-power-modes/active-power-smoothing-mode.jl")
include("mesa-modes/active-power-modes/active-power-following-modes.jl")
