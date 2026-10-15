"""
    CoordinatedChargeDischargeMode(params; SocUseTgtPct, DateTgt, WhReq=nothing)

Coordinated Charge/Discharge Management (IEEE 1815.2 6.4.5; 61850 DTCD). Type Replacing.

Reach `SocUseTgtPct` percent of usable capacity by `DateTgt`. Each tick the mode sets the average power needed,
(target energy − stored energy) / time remaining, as the base; the controller bounds it by the device limits and
maximum ramp rates (the function uses no ramp rates of its own). `WhReq`, when given, caps the energy moved. After
`DateTgt` the mode is inactive. Price-aware shaping (Figure 29 of the standard) is left to the scheduler.
"""
mutable struct CoordinatedChargeDischargeMode <: MesaMode
    params::MesaModeParams
    SocUseTgtPct::Float64
    DateTgt::DateTime
    WhReq::Union{Float64,Nothing}
end

CoordinatedChargeDischargeMode(params::MesaModeParams; SocUseTgtPct::Real, DateTgt::DateTime, WhReq = nothing) =
    CoordinatedChargeDischargeMode(params, Float64(SocUseTgtPct), DateTgt, _fl(WhReq))

kind(::Type{CoordinatedChargeDischargeMode}) = Replacing()

function modecontrol(
    mode::CoordinatedChargeDischargeMode,
    ess::EnergyStorageSystem,
    ::MesaController,
    ::TimeFrameRow,
    ::AbstractVector{<:UseCase},
    t::DateTime,
    _,
    ctx::ControlContext,
)
    t >= mode.DateTgt && return nothing
    hours = max((mode.DateTgt - t) / Hour(1), ctx.dt / 3600)
    needKwh = mode.SocUseTgtPct / 100 * e_max(ess) - energy_state(ess)   # positive: must charge
    if mode.WhReq !== nothing
        needKwh = clamp(needKwh, -mode.WhReq, mode.WhReq)
    end
    return Setpoint(-needKwh / hours)
end
