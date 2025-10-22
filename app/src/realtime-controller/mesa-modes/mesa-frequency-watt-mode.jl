using CtrlEvalEngine.EnergyStorageRTControl: MesaController, VertexCurve, RampParams


struct FrequencyWattMode <: MesaMode
    params::MesaModeParams
    useCurves::Bool
    frequencyWattCurve::VertexCurve
    lowHysteresisCurve::VertexCurve
    highHysteresisCurve::VertexCurve
    startDelay::Dates.Millisecond
    stopDelay::Dates.Millisecond
    rampParams::RampParams
    minimumSoc::Float64
    maximumSoc::Float64
    useHysteresis::Bool
    useSnapshotPower::Bool
    highStartingFrequency::Float64
    lowStartingFrequency::Float64
    highStoppingFrequency::Float64
    lowStoppingFrequency::Float64
    highDischargeGradient::Float64
    lowDischargeGradient::Float64
    highChargeGradient::Float64
    lowChargeGradient::Float64
    highReturnGradient::Float64
    lowReturnGradient::Float64
end

function modecontrol(
    mode::FrequencyWattMode,
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