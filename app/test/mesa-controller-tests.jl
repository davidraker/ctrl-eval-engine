# MESA controller tests. Included from controller-tests.jl, which provides `run_controller`, `ess` and `tStart`.
using CtrlEvalEngine
using CtrlEvalEngine.EnergyStorageUseCases
using CtrlEvalEngine.EnergyStorageUseCases: RegulationPricePoint
using CtrlEvalEngine.EnergyStorageScheduling: create_schedule_period
using Dates
using Test

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
    schedulePeriod = create_schedule_period(65.2, tStart; duration = Second(80))
    run_controller(ess, controller, schedulePeriod, useCases, tStart)
    println(raw_vector(controller.wip))
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
    schedulePeriod = create_schedule_period(65.2, tStart; duration = Second(268), regCapKw = 500.0)
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
    # KNOWN-WRONG EXPECTATION: the ramp of 50 kW per 5-minute step encodes the
    # missing time base in apply_ramps. At 10 %/s of 500 kW the first step would already reach 265 kW.
    # Rewritten in Phase 1.
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
        raw_vector(controller.wip) .==
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
        raw_vector(controller.wip) .==
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
        raw_vector(controller.wip) .== [
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

    # KNOWN-WRONG EXPECTATION: ActivePowerLimitMode only bounds what sorted before
    # it, so it is given the *larger* priority number here, inverting 1815.2 7.1 (zero is highest). Rewritten
    # in Phase 1 when the limit becomes a Bounding mode applied regardless of priority.
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
        raw_vector(controller.wip) .==
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
        raw_vector(controller.wip) .== [
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
        raw_vector(controller.wip) .==
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
        raw_vector(controller.wip) .==
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
    # @test raw_vector(controller.wip) ==
    #       [-2.0, -1.0, 0.0, 0.0, 0.0, 0.0, 0.0, -1.0, -2.0, -3.0, -4.0, -5.0]
end
