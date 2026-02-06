using CtrlEvalEngine.EnergyStorageRTControl: MesaController, VertexCurve, RampParams

struct VoltWattMode <: MesaMode
    params::MesaModeParams
    referenceVoltageOffset::Float64
    voltWattCurve::VertexCurve
    gradient::Float64
    filterTime::Dates.Second
    lowerDeadband::Float64
    upperDeadband::Float64
end

function modecontrol(
    mode::VoltWattMode,
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