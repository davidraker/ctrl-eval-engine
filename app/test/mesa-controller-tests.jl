using CtrlEvalEngine
using CtrlEvalEngine.EnergyStorageSimulators:
    LiIonBattery, LFP_LiIonBatterySpecs, LiIonBatteryStates, SOC, SOH, operate!
using CtrlEvalEngine.EnergyStorageUseCases
using CtrlEvalEngine.EnergyStorageUseCases: RegulationPricePoint

using CtrlEvalEngine.EnergyStorageScheduling: schedule, ManualScheduler, SchedulePeriod
using CtrlEvalEngine.EnergyStorageRTControl:
    control, PIDController, AMAController, RuleBasedController
using Dates
using JSON
using Test


function run_controller(ess, controller, schedulePeriod, useCases, tStart)
    t = tStart
    opHist = CtrlEvalEngine.OperationHistory([t], Float64[], Float64[SOC(ess)], [SOH(ess)])
    schedulePeriodEnd = min(end_time(schedulePeriod), tStart + Hour(1))
    spProgress = VariableIntervalTimeSeries([tStart], Float64[])
    while t < schedulePeriodEnd
        controlSequence = control(ess, controller, schedulePeriod, useCases, t, spProgress)
        for (powerSetpointKw, _, controlPeriodEnd) in controlSequence
            controlDuration = controlPeriodEnd - t
            actualPowerKw = operate!(ess, powerSetpointKw, controlDuration)
            CtrlEvalEngine.update_schedule_period_progress!(
                spProgress,
                actualPowerKw,
                controlDuration,
            )
            t += controlDuration
            CtrlEvalEngine.update_operation_history!(opHist, t, ess, actualPowerKw)
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

using CtrlEvalEngine.EnergyStorageRTControl:
    MesaController,
    MesaModeParams,
    RampParams,
    ActiveResponseMode,
    ChargeDischargeStorageMode,
    ActivePowerLimitMode,
    AGCMode,
    FrequencyWattMode

@testset "FrequencyWatt MESA Mode" begin
    useCases = UseCase[FrequencyResponse(
        FixedIntervalTimeSeries(
            tStart,
            Dates.Second(4),
            [
                60.0, 60.1, 60.2, 60.3, 60.4, 60.5, 60.6, 60.7, 60.8, 60.9,
                61.0, 61.1, 61.2, 61.3, 61.4, 61.5, 61.6, 61.7, 61.8, 61.9,
                62.0, 61.9, 61.8, 61.7, 61.6, 61.5, 61.4, 61.3, 61.2, 61.1,
                61.0, 60.9, 60.8, 60.7, 60.6, 60.5, 60.4, 60.3, 60.2, 60.1,
                60.0, 59.9, 59.8, 59.7, 59.6, 59.5, 59.4, 59.3, 59.2, 59.1,
                59.0, 58.9, 58.8, 58.7, 58.6, 58.5, 58.4, 58.3, 58.2, 58.1,
                58.0, 58.1, 58.2, 58.3, 58.4, 58.5, 58.6, 58.7, 58.8, 58.9,
                59.0, 59.1, 59.2, 59.3, 59.4, 59.5, 59.6, 59.7, 59.8, 59.9]),
        60
    )]
    controller = MesaController(
        [FrequencyWattMode(MesaModeParams(1), Millisecond(1000), Millisecond(1000), RampParams(100.0, 200.0, 100.0, 200.0), false, true, 61.0, 59.0, 60.5, 59.5, 10.0, 10.0, 20.0, 20.0)],
        Dates.Second(1)
    )
    schedulePeriod = SchedulePeriod(65.2, tStart, duration=Second(80))
    run_controller(ess, controller, schedulePeriod, useCases, tStart)
    println(controller.wip.value)
end

@testset "AGC MESA Mode" begin
    useCases = UseCase[Regulation(
        FixedIntervalTimeSeries(
            tStart,
            Dates.Second(4),
            [
                0.5080047394,
                0.5080047394,
                0.5080047394,
                0.5080047394,
                0.5080047394,
                0.5080047394,
                0.5080047394,
                0.5080047394,
                0.6667162504,
                0.6667162504,
                0.6667162504,
                0.6667162504,
                0.6667162504,
                0.6667162504,
                0.6667162504,
                0.6667162504,
                0.7466479844,
                0.7466479844,
                0.9304748861,
                0.9304548861,
                0.931176534,
                0.931176534,
                0.9337098728,
                0.9337098728,
                0.9353773848,
                0.9353773848,
                0.9353773848,
                -0.1019101319,
                -0.1019101319,
                -0.1019101319,
                -0.1019101319,
                -0.1019101319,
                -0.1019101319,
                -0.1019101319,
                -0.1019101319,
                -0.1019101319,
                -0.1019101319,
                -0.1019101319,
                -0.1019101319,
                -0.1019101319,
                -0.1019101319,
                -0.1019101319,
                -0.1019101319,
                -0.1019101319,
                -0.1019101319,
                -0.1019101319,
                -0.1019101319,
                -0.9019101319,
                -0.9019101319,
                -0.9019101319,
                -0.9019101319,
                -0.9019101319,
                -0.9019101319,
                -0.9019101319,
                -0.9019101319,
                -0.9019101319,
                -0.9019101319,
                -0.9019101319,
                -0.9019101319,
                -0.9019101319,
                -0.9019101319,
                -0.9019101319,
                -0.9019101319,
                -0.9019101319,
                -0.9019101319,
                -0.9019101319,
                -0.9019101319,
            ],
        ),
        FixedIntervalTimeSeries(tStart, Dates.Hour(1), [RegulationPricePoint(0.05, 0.42)]),
        50.0,
    )]
    schedulePeriod = create_schedule_period(65.2, tStart, Second(268), 0.0, 0.0, 500.0)
    controller = MesaController(
        [AGCMode(MesaModeParams(1), true, RampParams(100, 200, 100, 200), 40.0, 60.0)],
        Dates.Second(4),
    )
    run_controller(ess, controller, schedulePeriod, useCases, tStart)
end

@testset "Charge Discharge Storage MESA Mode" begin
    useCases = UseCase[]
    schedulePeriod = create_schedule_period(65.2, tStart; duration = Hour(1))

    # Test that mode follows the specified power percentage (53% of 500kW is 265kW).
    controller = MesaController(
        [
            ChargeDischargeStorageMode(
                MesaModeParams(1),
                true,
                RampParams(100.0, 200.0, 100.0, 200.0),
                20.0,
                80.0,
                53.0,
            ),
        ],
        Dates.Minute(5),
    )
    run_controller(ess, controller, schedulePeriod, useCases, tStart)
    @test all(
        controller.wip.value .==
        [50.0, 100.0, 150.0, 200.0, 250.0, 265.0, 265.0, 265.0, 265.0, 265.0, 265.0, 265.0],
    )

    # Test that mode follows the schedule if a power percentage is not specified .
    controller = MesaController(
        [
            ChargeDischargeStorageMode(
                MesaModeParams(1),
                true,
                RampParams(100.0, 200.0, 100.0, 200.0),
                20.0,
                80.0,
                nothing,
            ),
        ],
        Dates.Minute(5),
    )
    run_controller(ess, controller, schedulePeriod, useCases, tStart)
    @test all(
        controller.wip.value .==
        [50.0, 65.2, 65.2, 65.2, 65.2, 65.2, 65.2, 65.2, 65.2, 65.2, 65.2, 65.2],
    )

    # Test charging schedule (negative power):
    # Test that mode follows the schedule if a power percentage is not specified .
    controller = MesaController(
        [
            ChargeDischargeStorageMode(
                MesaModeParams(1),
                true,
                RampParams(100.0, 200.0, 100.0, 200.0),
                20.0,
                80.0,
                nothing,
            ),
        ],
        Dates.Minute(5),
    )
    schedulePeriod = create_schedule_period(-65.2, tStart; duration = Hour(1))
    run_controller(ess, controller, schedulePeriod, useCases, tStart)
    @test all(
        controller.wip.value .== [
            -65.2,
            -65.2,
            -65.2,
            -65.2,
            -65.2,
            -65.2,
            -65.2,
            -65.2,
            -65.2,
            -65.2,
            -65.2,
            -65.2,
        ],
    )
end

@testset "Active Power Limit MESA Mode" begin
    useCases = UseCase[]
    schedulePeriod = create_schedule_period(65.2, tStart; duration = Hour(1))
    rampParams = RampParams(100.0, 200.0, 100.0, 200.0)

    # Test Discharge Limit:
    controller = MesaController(
        [
            ChargeDischargeStorageMode(
                MesaModeParams(1),
                true,
                rampParams,
                20.0,
                80.0,
                nothing,
            ),
            ActivePowerLimitMode(MesaModeParams(2), 2.0, 1.0),
        ],
        Dates.Minute(5),
    )
    schedulePeriod = create_schedule_period(65.2, tStart; duration = Hour(1))
    run_controller(ess, controller, schedulePeriod, useCases, tStart)
    @test all(
        controller.wip.value .==
        [5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0],
    )

    # Test Charge Limit:
    controller = MesaController(
        [
            ChargeDischargeStorageMode(
                MesaModeParams(1),
                true,
                rampParams,
                20.0,
                80.0,
                nothing,
            ),
            ActivePowerLimitMode(MesaModeParams(2), 2.0, 1.0),
        ],
        Dates.Minute(5),
    )
    schedulePeriod = create_schedule_period(-65.2, tStart; duration = Hour(1))
    run_controller(ess, controller, schedulePeriod, useCases, tStart)
    @test all(
        controller.wip.value .== [
            -10.0,
            -10.0,
            -10.0,
            -10.0,
            -10.0,
            -10.0,
            -10.0,
            -10.0,
            -10.0,
            -10.0,
            -10.0,
            -10.0,
        ],
    )
end

@testset "PeakLimiting MESA Mode" begin
    useCases = UseCase[PeakLimiting(
        30,
        FixedIntervalTimeSeries(
            tStart,
            Dates.Minute(5),
            [10, 20, 30, 40, 50, 40, 30, 20, 10, 0, -10, -20],
        ),
    )]
    controller = MesaController(
        [ActiveResponseMode(MesaModeParams(1), 30.0, 1.0, 1000.0, 1000.0)],
        Dates.Minute(5),
    )
    schedulePeriod = create_schedule_period(65.2, tStart; duration = Hour(1))
    run_controller(ess, controller, schedulePeriod, useCases, tStart)

    @test all(
        controller.wip.value .==
        [0.0, 0.0, 0.0, 10.0, 20.0, 10.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
    )
end

@testset "LoadFollowing MESA Mode" begin
    useCases = UseCase[LoadFollowing(
        FixedIntervalTimeSeries(tStart, Dates.Minute(60), [30]),
        FixedIntervalTimeSeries(
            tStart,
            Dates.Minute(5),
            [10, 20, 30, 40, 50, 40, 30, 20, 10, 0, -10, -20],
        ),
    )]
    controller = MesaController(
        [ActiveResponseMode(MesaModeParams(1), 30.0, 10.0, 1000.0, 1000.0)],
        Dates.Minute(5),
    )
    schedulePeriod = create_schedule_period(65.2, tStart; duration = Hour(1))
    run_controller(ess, controller, schedulePeriod, useCases, tStart)
    @test all(
        controller.wip.value .==
        [0.0, 0.0, 0.0, 1.0, 2.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
    )
end

@testset "GenerationFollowing MESA Mode" begin
    useCases = UseCase[GenerationFollowing(
        FixedIntervalTimeSeries(tStart, Dates.Minute(60), [30]),
        FixedIntervalTimeSeries(
            tStart,
            Dates.Minute(5),
            [10, 20, 30, 40, 50, 40, 30, 20, 10, 0, -10, -20],
        ),
    )]
    controller = MesaController(
        [ActiveResponseMode(MesaModeParams(1), 30.0, 10.0, 1000.0, 1000.0)],
        Dates.Minute(5),
    )
    schedulePeriod = create_schedule_period(65.2, tStart; duration = Hour(1))
    run_controller(ess, controller, schedulePeriod, useCases, tStart)
    # @test controller.wip.value ==
    #       [-2.0, -1.0, 0.0, 0.0, 0.0, 0.0, 0.0, -1.0, -2.0, -3.0, -4.0, -5.0]
end
