using CtrlEvalEngine
using CtrlEvalEngine.EnergyStorageSimulators:
    LiIonBattery, LFP_LiIonBatterySpecs, LiIonBatteryStates, SOC, SOH, operate!
using CtrlEvalEngine.EnergyStorageUseCases
using CtrlEvalEngine.EnergyStorageUseCases: RegulationPricePoint

using CtrlEvalEngine.EnergyStorageScheduling: schedule, ManualScheduler, create_schedule_period
using CtrlEvalEngine.EnergyStorageRTControl:
    control, PIDController, AMAController, RuleBasedController
using Dates
using JSON
using Test

function run_controller(ess, controller, schedulePeriod, useCases, tStart)
    t = tStart
    opHist = TimeFrame(
        [t],
        [PeriodSeries{Float64}(), PointSeries([SOC(ess)]), PointSeries([SOH(ess)])],
        [:powerKw, :SOC, :SOH],
    )
    schedulePeriodEnd = min(end_time(schedulePeriod), tStart + Hour(1))
    spProgress = VariableIntervalTimeSeries([tStart], Float64[])
    while t < schedulePeriodEnd
        controlSequence = control(ess, controller, schedulePeriod, useCases, t, spProgress)
        for (powerSetpointKw, _, controlPeriodEnd) in controlSequence
            controlDuration = controlPeriodEnd - t
            operatingPoint = operate!(ess, powerSetpointKw, controlDuration)
            CtrlEvalEngine.update_schedule_period_progress!(
                spProgress,
                operatingPoint.powerKw,
                controlDuration,
            )
            t += controlDuration
            CtrlEvalEngine.update_operation_history!(opHist, t, operatingPoint)
            if t > schedulePeriodEnd
                break
            end
        end
    end
    return spProgress
end

ess =
    LiIonBattery(LFP_LiIonBatterySpecs(500, 10000, 0.85, 2000), LiIonBatteryStates(0.5, 0))
tStart = floor(now(), Hour(1))

include("mesa-controller-tests.jl")

@testset "PID Controller" begin
    useCases = UseCase[EnergyArbitrage(
        VariableIntervalTimeSeries(
            range(tStart; step = Hour(1), length = 5),
            [10, 20, 1, 10],
        ),
    )]
    controller = PIDController(Minute(1), 8.0, 0.5, 0.01)
    schedulePeriod = create_schedule_period(65.2, tStart; duration = Hour(1))
    run_controller(ess, controller, schedulePeriod, useCases, tStart)
    @test true
end

@testset "PID Controller" begin
    controller = PIDController(Second(1), 0.5, 0.5, 0.9)
    schedulePeriod = create_schedule_period(65.2, tStart; duration = Hour(1))
    lf = LoadFollowing(
        FixedIntervalTimeSeries(tStart, Minute(5), [10, 15, 1, 10]),
        FixedIntervalTimeSeries(tStart, Minute(5), [15, 10, 1, 10]),
    )
    gf = GenerationFollowing(
        FixedIntervalTimeSeries(tStart, Minute(5), [10, 15, 1, 10]),
        FixedIntervalTimeSeries(tStart, Minute(5), [15, 10, 1, 10]),
    )
    useCases = UseCase[lf]
    spProgress = run_controller(ess, controller, schedulePeriod, useCases, tStart)
    @test get_period(spProgress, tStart + Minute(4))[1] ≈ 70.2
    @test get_period(spProgress, tStart + Minute(9))[1] ≈ 60.2
    @test get_period(spProgress, tStart + Minute(14))[1] ≈ 65.2
    useCases = UseCase[gf]
    spProgress = run_controller(ess, controller, schedulePeriod, useCases, tStart)
    @test get_period(spProgress, tStart + Minute(4))[1] ≈ 60.2
    @test get_period(spProgress, tStart + Minute(9))[1] ≈ 70.2
    @test get_period(spProgress, tStart + Minute(14))[1] ≈ 65.2
    useCases = UseCase[lf, gf]
    let err = nothing
        try
            run_controller(ess, controller, schedulePeriod, useCases, tStart)
        catch err
        end
        @test err isa Exception
        @test sprint(showerror, err) ==
              "Disallowed set of UseCases: Only one of \"LoadFollowing\" and \"GenerationFollowing\" may be used"
    end
end
@testset "Rule-based Controller" begin
    useCases = UseCase[LoadFollowing(
        FixedIntervalTimeSeries(tStart, Minute(15), [20, 1, 10, 4]),
        FixedIntervalTimeSeries(
            tStart,
            Minute(5),
            [20.4, 18.2, 15, 6, 3, 0.5, 7, 6, 10, 11, 3, 2, 2.2],
        ),
    )]
    controller = RuleBasedController(1.5)
    schedulePeriod = create_schedule_period(65.2, tStart; duration = Minute(15))
    run_controller(ess, controller, schedulePeriod, useCases, tStart)
    @test true
end