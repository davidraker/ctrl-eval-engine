using Test
using Dates
using CtrlEvalEngine
using CtrlEvalEngine.EnergyStorageSimulators

@testset "Cell-level ratings" begin
    simulation = Dict(
        "ns" => 4,
        "np" => 2,
        "nm" => 3,
        "q_cell_ah" => 50.0,
        "v_cell_nom" => 3.2,
        "C_max" => 1.0,
    )
    bms = Dict("constraints" => Dict("soc_min" => 0.1, "soc_max" => 0.9))
    ratings = EnergyStorageSimulators.module_ratings(simulation, bms)
    expected_energy = 4 * 2 * 3 * 50 * 3.2 / 1000
    @test ratings.e_full_kwh ≈ expected_energy
    @test ratings.p_rated_kw ≈ expected_energy

    ess = CellLevelLiIonBattery(
        ratings,
        EnergyStorageSimulators.CellLevelStates(0.0, 0.5, 1.0, 0.95),
        Channel{String}(1),
        Channel{String}(1),
        nothing,
    )
    @test !hasproperty(ess, :base)
    @test !hasproperty(ess, :bmsRecords)
    @test e_max(ess) ≈ expected_energy
    @test e_min(ess) == 0.0
    @test p_max(ess) ≈ expected_energy
    @test p_min(ess) ≈ -expected_energy
    @test p_max(ess, 1.0, 25.0) ≈ 0.4 * expected_energy
    @test ηRT(ess) ≈ 0.95
    @test self_discharge_rate(ess) == 0.0

    payload = EnergyStorageSimulators.bms_compute_payload(12.5, 0.25, 20.0)
    @test payload[:payload][:power_kw] == 12.5
    @test payload[:payload][:duration_s] == 900.0

    response = Dict("state" => Dict("etaRt" => 0.91, "SOC" => 0.5))
    @test EnergyStorageSimulators._bms_nested(response, "etaRt", 1.0) == 0.91
end

function _cell_step(elapsed, current)
    EnergyStorageSimulators.CellStep(
        elapsed,
        1.0,
        0.49,
        1.0,
        0.48,
        0.50,
        3.1,
        3.3,
        3.2,
        12.8,
        25.0,
        26.0,
        25.5,
        current,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
    )
end

@testset "Cell-level operation history" begin
    ratings = EnergyStorageSimulators.module_ratings(
        Dict("ns" => 4, "np" => 1, "nm" => 1, "q_cell_ah" => 50.0, "v_cell_nom" => 3.2, "C_max" => 1.0),
        nothing,
    )
    ess = CellLevelLiIonBattery(
        ratings,
        EnergyStorageSimulators.CellLevelStates(0.0, 0.5, 1.0, 0.95),
        Channel{String}(1),
        Channel{String}(1),
        nothing,
    )
    t0 = DateTime(2024, 1, 1)
    operation = initialize_operation_history(t0, ess)
    result = EnergyStorageSimulators.CellLevelResult(
        1.0,
        0.48,
        1.0,
        [_cell_step(60.0, 10.0), _cell_step(120.0, 11.0)],
    )
    CtrlEvalEngine.update_operation_history!(operation, t0 + Hour(1), result)

    @test length(raw_vector(operation[:moduleCurrentA])) == 2
    @test length(raw_vector(operation[:cellSocMin])) == 3
    @test operation.t[2] == t0 + Millisecond(60_000)
    @test operation.t[3] == t0 + Millisecond(120_000)
    @test operation.t[end] != t0 + Hour(1)

    charts = CtrlEvalEngine.generate_chart_data(
        Progress(1.0, operation, operation),
        CtrlEvalEngine.UseCase[],
    )
    voltage = charts[findfirst(chart -> chart[:title] == "Cell Voltage", charts)]
    band = voltage[:data][1]
    @test band[:type] == "band"
    @test haskey(band, :yLow) && haskey(band, :yHigh)
    current = charts[findfirst(chart -> chart[:title] == "Module Current", charts)][:data][1]
    @test current[:type] == "interval"
    @test length(current[:y]) == length(raw_vector(operation[:moduleCurrentA]))
end
