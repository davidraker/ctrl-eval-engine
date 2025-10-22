
using CtrlEvalEngine.EnergyStorageRTControl:
    MesaController,
    MesaModeParams,
    RampParams,
    ActiveResponseMode,
    ChargeDischargeStorageMode,
    ActivePowerLimitMode,
    AGCMode

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
