# MESA controller tests. Included from controller-tests.jl (which provides `ess` and `tStart`); the tests here use
# their own MockSimulator instances so that outputs are exact.
using CtrlEvalEngine
using CtrlEvalEngine.EnergyStorageSimulators: MockSimulator, MockES_Specs, MockES_States, operate!, SOC
using CtrlEvalEngine.EnergyStorageUseCases
using CtrlEvalEngine.EnergyStorageUseCases: RegulationPricePoint, FrequencyResponse, VoltageControl
using CtrlEvalEngine.EnergyStorageScheduling: create_schedule_period
using CtrlEvalEngine.EnergyStorageRTControl
using CtrlEvalEngine.EnergyStorageRTControl:
    control, ramp_toward, apply_energy_limits, build_mode, get_rt_controller, ModeConflictError
using Dates
using Test

"A lossless 500 kW / 1000 kWh storage at `soc`."
mock_ess(; soc = 0.5, kw = 500.0, kwh = 1000.0) = MockSimulator(MockES_Specs(kw, kwh, 1.0), MockES_States(soc))

"Run `controller` from `tStart` to the end of the period (at most `duration`) and return its output series."
function run_mesa(ess, controller, schedulePeriod, useCases, tStart; duration = Hour(1))
    t = tStart
    tEnd = min(end_time(schedulePeriod), tStart + duration)
    spProgress = VariableIntervalTimeSeries([tStart], Float64[])
    while t < tEnd
        for (powerKw, _, tPeriodEnd) in control(ess, controller, schedulePeriod, useCases, t, spProgress)
            d = tPeriodEnd - t
            op = operate!(ess, powerKw, d)
            CtrlEvalEngine.update_schedule_period_progress!(spProgress, op.powerKw, d)
            t += d
        end
    end
    return raw_vector(controller.wip)
end

period(p, tStart; duration = Hour(1), kwargs...) = create_schedule_period(p, tStart; duration, kwargs...)
secs(tStart, values) = FixedIntervalTimeSeries(tStart, Second(1), float.(values))

@testset "Curve utilities" begin
    c = VertexCurve([(0.0, 0.0), (100.0, 1000.0)])
    @test evaluate_curve(c, 25.0) == 250.0
    @test evaluate_curve(c, -5.0) == 0.0
    @test evaluate_curve(c, 150.0) == 1000.0
    @test VertexCurve(Dict("crvPts" => [Dict("xVal" => 1, "yVal" => 2)])).vertices[1] == Vertex(1.0, 2.0)
    @test_throws ArgumentError VertexCurve([(1.0, 0.0), (1.0, 1.0)])
    @test_throws ArgumentError VertexCurve(Vertex[])
end

@testset "Ramp rates: units, time base and zero crossing" begin
    rp = RampParams(10.0, 10.0, 5.0, 5.0)                # % per second of WMax (500) and ChaWMax (500)
    @test ramp_toward(0.0, 265.0, 1.0, rp, 500.0, 500.0) == 50.0         # 10 %/s × 500 kW × 1 s
    @test ramp_toward(0.0, 265.0, 300.0, rp, 500.0, 500.0) == 265.0      # a 5-minute step reaches the target
    @test ramp_toward(100.0, -100.0, 4.0, rp, 500.0, 500.0) == -50.0     # 2 s down to zero, then 2 s × 25 kW/s
    @test ramp_toward(-100.0, 100.0, 4.0, rp, 500.0, 500.0) == 0.0       # the charge ramp-down (25 kW/s) uses the whole step
    @test ramp_toward(-100.0, 100.0, 6.0, rp, 500.0, 500.0) == 100.0     # 4 s to zero, then 2 s × 50 kW/s
    @test ramp_toward(0.0, 100.0, 1.0, RampParams(), 500.0, 500.0) == 100.0   # no rates: unlimited
end

@testset "Energy limits respect the sign convention" begin
    ess = mock_ess(soc = 0.5)
    @test apply_energy_limits(ess, 100.0, Hour(1), 45.0, 55.0) == 50.0    # 50 kWh above the 45 % reserve
    @test apply_energy_limits(ess, -100.0, Hour(1), 45.0, 55.0) == -50.0
    @test apply_energy_limits(ess, 20.0, Hour(1), 45.0, 55.0) == 20.0
end

@testset "Charge/Discharge Storage (DWGC)" begin
    # Percent target: 53 % of 500 kW is 265 kW, no ramp limit → reached in the first 5-minute step.
    ess = mock_ess()
    c = MesaController([ChargeDischargeStorageMode(MesaModeParams(1); GnWPctSpt = 53.0)], Minute(5))
    @test run_mesa(ess, c, period(65.2, tStart), UseCase[], tStart) == fill(265.0, 12)

    # Ramp rates in percent per second times the step: 10 %/s of 500 kW at a 1 s step is 50 kW per step.
    ess = mock_ess()
    c = MesaController(
        [ChargeDischargeStorageMode(MesaModeParams(1); GnWPctSpt = 53.0, rampParams = RampParams(10.0, 20.0, 10.0, 20.0))],
        Second(1),
    )
    @test run_mesa(ess, c, period(65.2, tStart; duration = Second(8)), UseCase[], tStart) ==
          [50.0, 100.0, 150.0, 200.0, 250.0, 265.0, 265.0, 265.0]

    # Negative percent is charging, referenced to ChaWMax.
    ess = mock_ess()
    c = MesaController([ChargeDischargeStorageMode(MesaModeParams(1); GnWPctSpt = -20.0)], Minute(5))
    @test run_mesa(ess, c, period(65.2, tStart; duration = Minute(10)), UseCase[], tStart) == [-100.0, -100.0]

    # Watts target takes precedence; no target follows the schedule.
    ess = mock_ess()
    c = MesaController([ChargeDischargeStorageMode(MesaModeParams(1); WSpt = 120.0, GnWPctSpt = 53.0)], Minute(5))
    @test run_mesa(ess, c, period(65.2, tStart; duration = Minute(5)), UseCase[], tStart) == [120.0]
    ess = mock_ess()
    c = MesaController([ChargeDischargeStorageMode(MesaModeParams(1))], Minute(5))
    @test run_mesa(ess, c, period(-65.2, tStart; duration = Minute(10)), UseCase[], tStart) == [-65.2, -65.2]

    # Time constants: open-loop response time of 10 s to reach 90 % of the change.
    ess = mock_ess()
    c = MesaController(
        [ChargeDischargeStorageMode(MesaModeParams(1); GnWPctSpt = 53.0, UseRmpRte = false, rampParams = RampParams(Second(10), Second(10)))],
        Second(1),
    )
    out = run_mesa(ess, c, period(0.0, tStart; duration = Second(10)), UseCase[], tStart)
    @test out[1] ≈ 265 * (1 - 0.1^(1 / 10))
    @test out[10] ≈ 265 * 0.9

    # The 3τ filter interpretation.
    ess = mock_ess()
    c = MesaController(
        [ChargeDischargeStorageMode(MesaModeParams(1); GnWPctSpt = 53.0, UseRmpRte = false, rampParams = RampParams(Second(30), Second(30)))],
        Second(1);
        OpnLoopTau = false,
    )
    out = run_mesa(ess, c, period(0.0, tStart; duration = Second(30)), UseCase[], tStart)
    @test out[1] ≈ 265 * (1 - exp(-1 / 10))
    @test out[30] ≈ 265 * (1 - exp(-3)) atol = 1e-9
end

@testset "Active Power Limit (DWMX/DWMN) bounds regardless of priority" begin
    for limitPriority in (0, 5)
        ess = mock_ess()
        c = MesaController(
            [
                ChargeDischargeStorageMode(MesaModeParams(1); GnWPctSpt = 53.0),
                ActivePowerLimitMode(MesaModeParams(limitPriority); LimWMax = 20.0, LimWMin = -10.0),
            ],
            Minute(5),
        )
        @test run_mesa(ess, c, period(65.2, tStart; duration = Minute(5)), UseCase[], tStart) == [100.0]
        @test mesa_status(c).boundBinding
        @test mesa_status(c).boundLo == -50.0 && mesa_status(c).boundHi == 100.0
    end
    # Charging side: the minimum is a consumption cap.
    ess = mock_ess()
    c = MesaController([ActivePowerLimitMode(MesaModeParams(2); LimWMax = 20.0, LimWMin = -10.0)], Minute(5))
    @test run_mesa(ess, c, period(-300.0, tStart; duration = Minute(5)), UseCase[], tStart) == [-50.0]
    # A negative maximum is a minimum consumption requirement.
    ess = mock_ess()
    c = MesaController([ActivePowerLimitMode(MesaModeParams(2); LimWMax = -10.0)], Minute(5))
    @test run_mesa(ess, c, period(265.0, tStart; duration = Minute(5)), UseCase[], tStart) == [-50.0]
    # Watts alternative and validation.
    ess = mock_ess()
    c = MesaController([ActivePowerLimitMode(MesaModeParams(2); LimWMaxKw = 42.0)], Minute(5))
    @test run_mesa(ess, c, period(265.0, tStart; duration = Minute(5)), UseCase[], tStart) == [42.0]
    @test_throws ArgumentError ActivePowerLimitMode(MesaModeParams(1); LimWMax = -10.0, LimWMin = 10.0)
end

@testset "Replacing modes: priority, not summation" begin
    ess = mock_ess()
    cd = ChargeDischargeStorageMode(MesaModeParams(2); GnWPctSpt = 53.0)
    agc = AGCMode(MesaModeParams(1); WSpt = 100.0)
    c = MesaController([cd, agc], Minute(5))
    @test run_mesa(ess, c, period(65.2, tStart; duration = Minute(5)), UseCase[], tStart) == [100.0]
    st = mesa_status(c)
    @test st.baseMode == 2 && st.active == [true, true] && st.suppressed == [true, false]
    @test st.attempted == [265.0, 100.0]

    # Equal priority: the most recently activated wins (7.2, priority of last command).
    ess = mock_ess()
    cd = ChargeDischargeStorageMode(MesaModeParams(1); GnWPctSpt = 53.0)
    agc = AGCMode(MesaModeParams(1; ModEna = false); WSpt = 100.0)
    c = MesaController([cd, agc], Second(1))
    sp = period(0.0, tStart; duration = Second(10))
    spProgress = VariableIntervalTimeSeries([tStart], Float64[])
    outputs = Float64[]
    for k = 0:4
        t = tStart + Second(k)
        k == 2 && enable!(c, agc, t)
        seq = control(ess, c, sp, UseCase[], t, spProgress)
        p = raw_vector(seq)[1]
        push!(outputs, p)
        op = operate!(ess, p, Second(1))
        CtrlEvalEngine.update_schedule_period_progress!(spProgress, op.powerKw, Second(1))
    end
    @test outputs == [265.0, 265.0, 100.0, 100.0, 100.0]
    @test mesa_status(c).baseMode == 2
end

@testset "Additive modes: equal priorities sum, different priorities suppress" begin
    load = UseCase[LoadFollowing(secs(tStart, fill(130, 10)), secs(tStart, fill(130, 10)))]
    for (prio2, expected, suppressed) in ((3, 30.0, [false, false]), (4, 15.0, [false, true]))
        ess = mock_ess()
        c = MesaController(
            [
                LoadFollowingMode(MesaModeParams(3); FolWThr = 100.0, FolWPct = 50.0),
                LoadFollowingMode(MesaModeParams(prio2); FolWThr = 100.0, FolWPct = 50.0),
            ],
            Second(1),
        )
        @test run_mesa(ess, c, period(0.0, tStart; duration = Second(3)), load, tStart) == fill(expected, 3)
        @test mesa_status(c).suppressed == suppressed
        @test mesa_status(c).attempted == [15.0, 15.0]
    end
end

@testset "Replacing a mode in place keeps its state" begin
    ess = mock_ess()
    cd = ChargeDischargeStorageMode(MesaModeParams(1; RvrtTms = 5); GnWPctSpt = 53.0)
    c = MesaController([cd], Second(1))
    sp = period(0.0, tStart; duration = Second(10))
    spProgress = VariableIntervalTimeSeries([tStart], Float64[])
    outputs = Float64[]
    for k = 0:6
        t = tStart + Second(k)
        if k == 2   # re-parameterise: 20 % instead of 53 %, same timing; the reversion clock keeps running
            replace_mode!(c, 1, ChargeDischargeStorageMode(MesaModeParams(1; RvrtTms = 5); GnWPctSpt = 20.0))
        end
        p = raw_vector(control(ess, c, sp, UseCase[], t, spProgress))[1]
        push!(outputs, p)
        op = operate!(ess, p, Second(1))
        CtrlEvalEngine.update_schedule_period_progress!(spProgress, op.powerKw, Second(1))
    end
    @test outputs == [265.0, 265.0, 100.0, 100.0, 100.0, 0.0, 0.0]
    @test_throws ModeConflictError replace_mode!(
        MesaController([AGCMode(MesaModeParams(1); WSpt = 1.0), ChargeDischargeStorageMode(MesaModeParams(2))], Second(1)),
        2,
        ActivePowerSmoothingMode(MesaModeParams(2); WSmthGra = 1.0, FilTms = 10),
    )
end

@testset "Mutual exclusion (Table 58)" begin
    smoothing(ena) = ActivePowerSmoothingMode(MesaModeParams(2; ModEna = ena); WSmthGra = -0.5, FilTms = Second(10))
    @test_throws ModeConflictError MesaController([AGCMode(MesaModeParams(1); WSpt = 1.0), smoothing(true)], Second(1))
    c = MesaController(
        [
            AGCMode(MesaModeParams(1); WSpt = 1.0),
            ChargeDischargeStorageMode(MesaModeParams(2)),
            ActivePowerLimitMode(MesaModeParams(3); LimWMax = 50.0),
            smoothing(false),
        ],
        Second(1),
    )
    @test_throws ModeConflictError enable!(c, 4, tStart)
    disable!(c, 1)
    @test enable!(c, 4, tStart) isa ActivePowerSmoothingMode
    @test_throws ModeConflictError enable!(c, 1, tStart)
end

@testset "Enabling time window, ramp time and reversion timeout (6.1.2)" begin
    # Deterministic window: the function starts at the end of the window.
    ess = mock_ess()
    c = MesaController([ChargeDischargeStorageMode(MesaModeParams(1; WinTms = 5); GnWPctSpt = 53.0)], Second(1))
    @test run_mesa(ess, c, period(0.0, tStart; duration = Second(8)), UseCase[], tStart) ==
          [0.0, 0.0, 0.0, 0.0, 0.0, 265.0, 265.0, 265.0]

    # Seeded window: reproducible start inside the window.
    starts = Int[]
    for _ = 1:2
        ess = mock_ess()
        c = MesaController(
            [ChargeDischargeStorageMode(MesaModeParams(1; WinTms = 5); GnWPctSpt = 53.0)],
            Second(1);
            randomSeed = 7,
        )
        out = run_mesa(ess, c, period(0.0, tStart; duration = Second(8)), UseCase[], tStart)
        push!(starts, findfirst(==(265.0), out))
    end
    @test starts[1] == starts[2] && 1 <= starts[1] <= 6

    # Enabling ramp time: the contribution moves linearly from the starting power to the target.
    ess = mock_ess()
    c = MesaController([ChargeDischargeStorageMode(MesaModeParams(1; RmpTms = 10); GnWPctSpt = 53.0)], Second(1))
    out = run_mesa(ess, c, period(0.0, tStart; duration = Second(12)), UseCase[], tStart)
    @test out ≈ vcat([265 * k / 10 for k = 0:10], 265.0) atol = 1e-9

    # Reversion timeout disables the function.
    ess = mock_ess()
    cd = ChargeDischargeStorageMode(MesaModeParams(1; RvrtTms = 5); GnWPctSpt = 53.0)
    c = MesaController([cd], Second(1))
    @test run_mesa(ess, c, period(0.0, tStart; duration = Second(8)), UseCase[], tStart) ==
          [265.0, 265.0, 265.0, 265.0, 265.0, 0.0, 0.0, 0.0]
    @test !is_enabled(cd) && !mesa_status(c).enabled[1]
end

@testset "Storage reserves and device ramp rates" begin
    ess = mock_ess(soc = 0.5)
    c = MesaController([ChargeDischargeStorageMode(MesaModeParams(1); GnWPctSpt = 53.0)], Hour(1); SocUseMinPct = 45.0)
    @test run_mesa(ess, c, period(0.0, tStart; duration = Hour(1)), UseCase[], tStart) == [50.0]
    @test mesa_status(c).reserveBinding

    # Device maximum ramp rates (DCTE) bind after the function's own rates: 4 %/s of 500 kW is 20 kW/s.
    ess = mock_ess()
    c = MesaController(
        [ChargeDischargeStorageMode(MesaModeParams(1); GnWPctSpt = 53.0, rampParams = RampParams(10.0, 10.0, 10.0, 10.0))],
        Second(1);
        maxRampRates = RampParams(4.0, 4.0, 4.0, 4.0),
    )
    @test run_mesa(ess, c, period(0.0, tStart; duration = Second(3)), UseCase[], tStart) == [20.0, 40.0, 60.0]
    @test mesa_status(c).rampBinding
end

@testset "AGC (DAGC)" begin
    # Direct watts target.
    ess = mock_ess()
    c = MesaController([AGCMode(MesaModeParams(1); WSpt = 100.0)], Minute(5))
    @test run_mesa(ess, c, period(65.2, tStart; duration = Minute(5)), UseCase[], tStart) == [100.0]
    @test mesa_status(c).extras[1][:WMaxAvl] == 500.0

    # Per-unit path through a Regulation use case and the period's regulation capacity.
    reg = UseCase[Regulation(
        FixedIntervalTimeSeries(tStart, Second(4), [0.5, 0.5, -0.2]),
        FixedIntervalTimeSeries(tStart, Hour(1), [RegulationPricePoint(0.05, 0.42)]),
        50.0,
    )]
    ess = mock_ess()
    c = MesaController([AGCMode(MesaModeParams(1))], Second(4))
    @test run_mesa(ess, c, period(65.2, tStart; duration = Second(12), regCapKw = 500.0), reg, tStart) ==
          [250.0, 250.0, -100.0]

    # No target: enabled but inactive, the base follows the schedule.
    ess = mock_ess()
    c = MesaController([AGCMode(MesaModeParams(1))], Minute(5))
    @test run_mesa(ess, c, period(65.2, tStart; duration = Minute(5)), UseCase[], tStart) == [65.2]
    @test !mesa_status(c).active[1]

    # Own SOC window.
    ess = mock_ess(soc = 0.5)
    c = MesaController([AGCMode(MesaModeParams(1); WSpt = 100.0, SocUseMinPct = 60.0)], Minute(5))
    @test run_mesa(ess, c, period(65.2, tStart; duration = Minute(5)), UseCase[], tStart) == [0.0]
end

@testset "Coordinated Charge/Discharge (DTCD)" begin
    ess = mock_ess(soc = 0.5)
    c = MesaController(
        [CoordinatedChargeDischargeMode(MesaModeParams(1); SocUseTgtPct = 80.0, DateTgt = tStart + Hour(2))],
        Hour(1),
    )
    @test run_mesa(ess, c, period(0.0, tStart; duration = Hour(3)), UseCase[], tStart; duration = Hour(3)) ==
          [-150.0, -150.0, 0.0]
    @test SOC(ess) ≈ 0.8
end

@testset "Frequency-Watt droop (DHFW3/DLFW3)" begin
    f = UseCase[FrequencyResponse(secs(tStart, [60.0, 60.0, 60.3, 60.3, 60.0, 60.0]), 60.0)]
    ess = mock_ess()
    # 1547 default droop 0.05 ↔ 20 % of WMax per percent frequency; 0.264 Hz beyond the deadband is 0.44 %.
    c = MesaController([FrequencyWattDroopMode(MesaModeParams(1); HzStrHi = 60.036, HzStrLo = 59.964, WGraHi = 20.0)], Second(1))
    out = run_mesa(ess, c, period(100.0, tStart; duration = Second(6)), f, tStart)
    @test out ≈ [100.0, 100.0, 56.0, 56.0, 100.0, 100.0]
    @test mesa_status(c).active == [false]

    # Low side with the WMaxPct cap.
    f = UseCase[FrequencyResponse(secs(tStart, [60.0, 58.0]), 60.0)]
    ess = mock_ess()
    c = MesaController(
        [FrequencyWattDroopMode(MesaModeParams(1); HzStrHi = 60.036, HzStrLo = 59.964, WGraHi = 20.0, WMaxPct = 60.0)],
        Second(1),
    )
    # 1.964 Hz below the deadband is 3.27 %, worth 327 kW; the WMaxPct cap holds the result at 300 kW.
    @test run_mesa(ess, c, period(100.0, tStart; duration = Second(2)), f, tStart) == [100.0, 300.0]
end

@testset "Frequency-Watt sensitivity (DHFW1/DLFW1)" begin
    mode() = FrequencyWattMode(
        MesaModeParams(1);
        HzStrHi = 60.1, HzStopHi = 60.05, HzStrLo = 59.9, HzStopLo = 59.95,
        WGraHi = 10.0, WChaGraHi = 20.0, WGraLo = 10.0, WChaGraLo = 20.0,
    )
    # 1 % over nominal with a 10 %-per-percent gradient removes 50 kW from the 100 kW snapshot.
    f = UseCase[FrequencyResponse(secs(tStart, [60.0, 60.6, 60.6, 60.0]), 60.0)]
    ess = mock_ess()
    c = MesaController([mode()], Second(1))
    @test run_mesa(ess, c, period(100.0, tStart; duration = Second(4)), f, tStart) ≈ [100.0, 50.0, 50.0, 100.0]

    # 3 % over nominal: 2 % to reach zero, the remaining 1 % on the charging gradient (20 % of ChaWMax).
    f = UseCase[FrequencyResponse(secs(tStart, [60.0, 61.8]), 60.0)]
    ess = mock_ess()
    c = MesaController([mode()], Second(1))
    @test run_mesa(ess, c, period(100.0, tStart; duration = Second(2)), f, tStart) ≈ [100.0, -100.0]

    # Start delay and stop delay: activation one second after crossing HzStrHi; while the stop delay runs the
    # function is still active and follows the gradient (60.03 Hz is 0.05 %, 2.5 kW).
    f = UseCase[FrequencyResponse(secs(tStart, [60.0, 60.6, 60.6, 60.6, 60.03, 60.03, 60.03]), 60.0)]
    ess = mock_ess()
    m = mode()
    m.ActStrDlTmms = Millisecond(1000)
    m.ActStopDlTmms = Millisecond(1000)
    c = MesaController([m], Second(1))
    @test run_mesa(ess, c, period(100.0, tStart; duration = Second(7)), f, tStart) ≈
          [100.0, 100.0, 50.0, 50.0, 97.5, 100.0, 100.0]

    # Hysteresis holds the most extreme value until the stop frequency.
    f = UseCase[FrequencyResponse(secs(tStart, [60.0, 60.6, 60.3, 60.3, 60.0]), 60.0)]
    ess = mock_ess()
    m = mode()
    m.HysEna = true
    c = MesaController([m], Second(1))
    @test run_mesa(ess, c, period(100.0, tStart; duration = Second(5)), f, tStart) ≈ [100.0, 50.0, 50.0, 50.0, 100.0]
    # Without hysteresis the target follows the frequency back.
    ess = mock_ess()
    c = MesaController([mode()], Second(1))
    @test run_mesa(ess, c, period(100.0, tStart; duration = Second(5)), f, tStart) ≈ [100.0, 50.0, 75.0, 75.0, 100.0]

    # Snapshot disabled: the gradient is a boundary from WMax that a 100 kW base does not reach.
    f = UseCase[FrequencyResponse(secs(tStart, [60.0, 60.6]), 60.0)]
    ess = mock_ess()
    m = mode()
    m.SnptEna = false
    c = MesaController([m], Second(1))
    @test run_mesa(ess, c, period(100.0, tStart; duration = Second(2)), f, tStart) == [100.0, 100.0]
    ess = mock_ess()
    m = mode()
    m.SnptEna = false
    c = MesaController([m], Second(1))
    @test run_mesa(ess, c, period(480.0, tStart; duration = Second(2)), f, tStart) ≈ [480.0, 450.0]

    # Own SOC window: no discharge increase at or below SocUseMinPct.
    f = UseCase[FrequencyResponse(secs(tStart, [60.0, 59.4]), 60.0)]
    ess = mock_ess(soc = 0.2)
    m = mode()
    m.SocUseMinPct = 30.0
    c = MesaController([m], Second(1))
    @test run_mesa(ess, c, period(100.0, tStart; duration = Second(2)), f, tStart) == [100.0, 100.0]
end

@testset "Frequency-Watt curve (DHFW2/DLFW2)" begin
    # x: percent deviation from nominal; y: percent of WMax (negative: of ChaWMax). From 0 at 0.1 % to -50 % at 1.1 %.
    crv = [(0.1, 0.0), (1.1, -50.0)]
    f = UseCase[FrequencyResponse(secs(tStart, [60.0, 60.6, 60.0]), 60.0)]
    ess = mock_ess()
    c = MesaController(
        [FrequencyWattCurveMode(MesaModeParams(1); HzWCrv = crv, HzStrHi = 60.06, HzStrLo = 59.94)],
        Second(1),
    )
    # At 1 % the curve gives -45 % of ChaWMax = -225 kW relative to its value at the start frequency (0).
    @test run_mesa(ess, c, period(100.0, tStart; duration = Second(3)), f, tStart) ≈ [100.0, -125.0, 100.0]
end

@testset "Volt-Watt (DVWC)" begin
    v = UseCase[VoltageControl(secs(tStart, [120.0, 129.6, 129.6, 120.0]), 120.0)]
    ess = mock_ess()
    c = MesaController(
        [VoltWattMode(MesaModeParams(1); VWCrv = volt_watt_curve(106.0, 100.0, 110.0, 0.0))],
        Second(1),
    )
    # 108 % of VRef: halfway down the curve, maximum 50 % of WMax = 250 kW.
    @test run_mesa(ess, c, period(400.0, tStart; duration = Second(4)), v, tStart) ≈ [400.0, 250.0, 250.0, 400.0]
    # A base below the bound is untouched.
    ess = mock_ess()
    c = MesaController(
        [VoltWattMode(MesaModeParams(1); VWCrv = volt_watt_curve(106.0, 100.0, 110.0, 0.0))],
        Second(1),
    )
    @test run_mesa(ess, c, period(100.0, tStart; duration = Second(4)), v, tStart) ≈ [100.0, 100.0, 100.0, 100.0]
    # Low-voltage branch: a minimum generation.
    v = UseCase[VoltageControl(secs(tStart, [120.0, 110.4]), 120.0)]
    ess = mock_ess()
    c = MesaController(
        [VoltWattMode(MesaModeParams(1); VWCrv = volt_watt_curve(106.0, 100.0, 110.0, 0.0), VWCrvLo = volt_watt_curve(90.0, 60.0, 94.0, 0.0))],
        Second(1),
    )
    @test run_mesa(ess, c, period(0.0, tStart; duration = Second(2)), v, tStart) ≈ [0.0, 150.0]
end

@testset "Dynamic Volt-Watt (DVWD)" begin
    v = UseCase[VoltageControl(secs(tStart, [120.0, 120.0, 120.0, 121.2, 120.0]), 120.0)]
    ess = mock_ess()
    c = MesaController([DynamicVoltWattMode(MesaModeParams(1); DynVWGra = 10.0, VWFilTms = 10)], Second(1))
    # +1 % above the moving average × 10 % of WMax per percent → absorb 50 kW.
    out = run_mesa(ess, c, period(0.0, tStart; duration = Second(5)), v, tStart)
    @test out[1:4] ≈ [0.0, 0.0, 0.0, -50.0]
    @test out[5] ≈ 12.5 atol = 1e-9      # the average is now 120.3, so 120 V is -0.25 %: inject 2.5 % of WMax
    # Deadband.
    ess = mock_ess()
    c = MesaController([DynamicVoltWattMode(MesaModeParams(1); DynVWGra = 10.0, DbVWLo = -2.0, DbVWHi = 2.0, VWFilTms = 10)], Second(1))
    @test run_mesa(ess, c, period(0.0, tStart; duration = Second(4)), v, tStart) == [0.0, 0.0, 0.0, 0.0]
end

@testset "Active Power Smoothing (DWSM)" begin
    pv = UseCase[VariabilityMitigation(secs(tStart, [100.0, 100.0, 100.0, 140.0, 140.0]), 500.0)]
    ess = mock_ess()
    c = MesaController(
        [ActivePowerSmoothingMode(MesaModeParams(1); WSmthGra = -0.5, WSmthLoLim = -10.0, WSmthHiLim = 10.0, FilTms = 10)],
        Second(1),
    )
    out = run_mesa(ess, c, period(0.0, tStart; duration = Second(5)), pv, tStart)
    @test out[1:4] ≈ [0.0, 0.0, 0.0, -20.0]            # a 40 kW jump above the 100 kW average, half absorbed
    @test out[5] ≈ -0.5 * (140 - 110)                   # the average now includes the first 140 kW sample
    # Mutually exclusive with AGC.
    @test_throws ModeConflictError MesaController(
        [AGCMode(MesaModeParams(1); WSpt = 1.0), ActivePowerSmoothingMode(MesaModeParams(2); WSmthGra = 1.0, FilTms = 10)],
        Second(1),
    )
end

@testset "Active Power Response (DWFL1..3)" begin
    ref = secs(tStart, [10, 20, 30, 40, 50, 40, 30, 20, 10, 0, -10, -20])
    # Peak Power Limiting is a lower bound on the ESS output.
    ess = mock_ess()
    c = MesaController([PeakPowerLimitingMode(MesaModeParams(1); FolWThr = 30.0)], Second(1))
    @test run_mesa(ess, c, period(0.0, tStart; duration = Second(12)), UseCase[PeakLimiting(30, ref)], tStart) ==
          [0.0, 0.0, 0.0, 10.0, 20.0, 10.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
    # A base above the bound is left alone.
    ess = mock_ess()
    c = MesaController([PeakPowerLimitingMode(MesaModeParams(1); FolWThr = 30.0)], Second(1))
    @test run_mesa(ess, c, period(15.0, tStart; duration = Second(5)), UseCase[PeakLimiting(30, ref)], tStart) ==
          [15.0, 15.0, 15.0, 15.0, 20.0]
    # Load Following adds the ratio of the excess.
    ess = mock_ess()
    c = MesaController([LoadFollowingMode(MesaModeParams(1); FolWThr = 30.0, FolWPct = 10.0)], Second(1))
    load = UseCase[LoadFollowing(secs(tStart, fill(30, 12)), ref)]
    @test run_mesa(ess, c, period(0.0, tStart; duration = Second(12)), load, tStart) ==
          [0.0, 0.0, 0.0, 1.0, 2.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
    # Generation Following absorbs the generation above the threshold.
    ess = mock_ess()
    c = MesaController([GenerationFollowingMode(MesaModeParams(1); FolWThr = 30.0, FolWPct = 10.0)], Second(1))
    gen = UseCase[GenerationFollowing(secs(tStart, fill(30, 12)), ref)]
    @test run_mesa(ess, c, period(0.0, tStart; duration = Second(12)), gen, tStart) ==
          [0.0, 0.0, 0.0, -1.0, -2.0, -1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
    # Ramp rates: 1 %/s of 500 kW is 5 kW per second.
    ess = mock_ess()
    c = MesaController(
        [LoadFollowingMode(MesaModeParams(1); FolWThr = 0.0, FolWPct = 100.0, rampParams = RampParams(1.0, 1.0, 1.0, 1.0))],
        Second(1),
    )
    @test run_mesa(ess, c, period(0.0, tStart; duration = Second(3)), load, tStart) == [5.0, 10.0, 15.0]
end

@testset "Meter inputs by EcpRef" begin
    meters = Dict(:pcc => MeterReadings(; Hz = secs(tStart, [60.0, 60.6]), HzNom = 60.0))
    ess = mock_ess()
    c = MesaController(
        [FrequencyWattMode(MesaModeParams(1); HzStrHi = 60.1, HzStrLo = 59.9, WGraHi = 10.0, WGraLo = 10.0, EcpRef = :pcc)],
        Second(1);
        meters,
    )
    @test run_mesa(ess, c, period(100.0, tStart; duration = Second(2)), UseCase[], tStart) ≈ [100.0, 50.0]
    # A live reading.
    set_reading!(meters[:pcc], :Hz, 60.0)
    ess = mock_ess()
    c = MesaController(
        [FrequencyWattMode(MesaModeParams(1); HzStrHi = 60.1, HzStrLo = 59.9, WGraHi = 10.0, WGraLo = 10.0, EcpRef = :pcc)],
        Second(1);
        meters,
    )
    @test run_mesa(ess, c, period(100.0, tStart; duration = Second(2)), UseCase[], tStart) == [100.0, 100.0]
end

@testset "Configuration" begin
    cfg = Dict(
        "type" => "mesa",
        "resolutionSec" => 300,
        "maxRampRates" => Dict("RpuRteMax" => 20, "RpdRteMax" => 20),
        "SocUseMinPct" => 10,
        "SocUseMaxPct" => 90,
        "randomSeed" => 1,
        "meters" => Dict("pcc" => Dict("HzNom" => 60, "VRef" => 120)),
        "modes" => [
            Dict("type" => "chargeDischarge", "ModPrio" => 2, "GnWPctSpt" => 53, "RpuRte" => 10, "RpdRte" => 20),
            Dict("type" => "DWMX", "priority" => 1, "LimWMax" => 80, "LimWMin" => -50),
            Dict("type" => "frequencyWattDroop", "ModPrio" => 1, "enabled" => false, "EcpRef" => "pcc",
                 "HzStrHi" => 60.036, "HzStrLo" => 59.964, "WGraHi" => 20, "RmpUpTms" => 5),
            Dict("type" => "voltWatt", "ModPrio" => 3, "VWCrv" => Dict("crvPts" => [Dict("xVal" => 106, "yVal" => 100), Dict("xVal" => 110, "yVal" => 0)])),
            Dict("type" => "DWFL1", "ModPrio" => 4, "FolWThr" => 30),
        ],
    )
    ess = mock_ess()
    c = get_rt_controller(cfg, ess, UseCase[])
    @test c isa MesaController && c.resolution == Millisecond(300_000)
    @test typeof.(c.modes) == [
        ChargeDischargeStorageMode, ActivePowerLimitMode, FrequencyWattDroopMode, VoltWattMode, PeakPowerLimitingMode,
    ]
    @test c.modes[1].rampParams.RpuRte == 10.0 && c.modes[1].params.ModPrio == 2
    @test c.modes[2].params.ModPrio == 1 && c.modes[2].LimWMin == -50.0
    @test !is_enabled(c.modes[3]) && c.modes[3].EcpRef == :pcc && c.modes[3].rampParams.RmpUpTms == Second(5)
    @test c.maxRampRates.RpuRte == 20.0 && c.SocUseMinPct == 10.0 && c.rng !== nothing
    @test c.meters[:pcc].VRef == 120.0
    @test run_mesa(ess, c, period(0.0, tStart; duration = Minute(5)), UseCase[], tStart) == [265.0]
    @test_throws InvalidInput build_mode(Dict("type" => "noSuchMode"))
end
