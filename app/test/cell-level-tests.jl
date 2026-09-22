using Test
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
    ratings = EnergyStorageSimulators.cell_pack_ratings(simulation, bms)
    expected_energy = 4 * 2 * 3 * 50 * 3.2 / 1000
    @test ratings.e_full_kwh ≈ expected_energy
    @test ratings.p_rated_kw ≈ expected_energy

    ess = CellLevelLiIonBattery(
        ratings,
        0.95,
        Channel{String}(1),
        Channel{String}(1),
        nothing,
        Dict{String,Any}("powerKw" => 0.0, "SOC" => 0.5, "SOH" => 1.0),
        Dict{String,Any}[],
        Dict{String,Any}(),
        Dict{String,Any}(),
        String[],
    )
    @test !hasproperty(ess, :base)
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

    response = Dict(
        "message" => "Initialized",
        "state" => Dict("bmsSummary" => Dict("cells" => 1), "etaRt" => 0.91, "SOC" => 0.5),
    )
    @test EnergyStorageSimulators._bms_nested(response, "bmsSummary", Dict())["cells"] == 1
    @test EnergyStorageSimulators._bms_nested(response, "etaRt", 1.0) == 0.91
end
