using CtrlEvalEngine.EnergyStorageRTControl: MesaController, VertexCurve, RampParams

struct ActivePowerSmoothingMode <: MesaMode
    params::MesaModeParams
    smoothingGradient::Float64
    lowerSmoothingLimit::Float64
    upperSmoothingLimit::Float64
    smoothingFilterTime::Dates.Second
    rampParams::RampParams
end


function modecontrol(
    mode::ActivePowerSmoothingMode,
    ess::EnergyStorageSystem,
    controller::MesaController,
    schedulePeriod::TimeFrameRow,
    useCases::AbstractVector{<:UseCase},
    t::Dates.DateTime,
    spProgress::VariableIntervalTimeSeries,
    currentIterationPower::Float64
)
    # TODO: Stuff
end
