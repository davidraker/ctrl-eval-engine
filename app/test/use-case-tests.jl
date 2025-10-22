
using CtrlEvalEngine:
    ScheduleHistory, OperationHistory, Progress, VariableIntervalTimeSeries
using CtrlEvalEngine.EnergyStorageUseCases
using Dates
using LinearAlgebra

@testset "Use Cases" begin
    @testset "Energy Net Income" begin
        @test OperationHistory(
            DateTime(2022, 1, 1):Hour(1):DateTime(2022, 1, 1, 4),
            [1.0, 1.0, 1.0, 1.0],
            zeros(5),
            ones(5),
        )[:powerKw] ⋅ VariableIntervalTimeSeries(
            DateTime(2022, 1, 1):Hour(1):DateTime(2022, 1, 1, 4),
            [1.0, 2.0, 3.0, 4.0],
        ) == 10.0

        @test OperationHistory(
            DateTime(2022, 1, 1):Hour(1):DateTime(2022, 1, 1, 4),
            [-1.0, -1.0, 1.0, 1.0],
            zeros(5),
            ones(5),
        )[:powerKw] ⋅ VariableIntervalTimeSeries(
            DateTime(2022, 1, 1):Hour(1):DateTime(2022, 1, 1, 4),
            [1.0, 2.0, 3.0, 4.0],
        ) == 4.0

        @test OperationHistory(
            DateTime(2022, 1, 1):Hour(1):DateTime(2022, 1, 1, 4),
            [-1.0, -1.0, 1.0, 1.0],
            zeros(5),
            ones(5),
        )[:powerKw] ⋅ VariableIntervalTimeSeries(
            DateTime(2022, 1, 1):Minute(30):DateTime(2022, 1, 1, 4),
            [1.0, 0.0, 2.0, 0.0, 3.0, 0.0, 4.0, 0.0],
        ) == 2.0

        @test OperationHistory(
            DateTime(2022, 1, 1):Minute(30):DateTime(2022, 1, 1, 4),
            [-1.0, 0.0, -1.0, 0.0, 1.0, 0.0, 1.0, 0.0],
            zeros(9),
            ones(9),
        )[:powerKw] ⋅ VariableIntervalTimeSeries(
            DateTime(2022, 1, 1):Hour(1):DateTime(2022, 1, 1, 4),
            [1.0, 2.0, 3.0, 4.0],
        ) == 2.0

        @test OperationHistory(
            [
                DateTime("2022-01-01T00:30"),
                DateTime("2022-01-01T01:15"),
                DateTime("2022-01-01T02:00"),
                DateTime("2022-01-01T03:45"),
            ],
            [1.0, -1.0, 1.0],
            zeros(4),
            ones(4),
        )[:powerKw] ⋅ VariableIntervalTimeSeries(
            DateTime(2022, 1, 1):Hour(1):DateTime(2022, 1, 1, 4),
            [1.0, 2.0, 3.0, 4.0],
        ) == 1.0 * 0.5 + 2.0 * 0.25 + 2.0 * -0.75 + 3.0 + 4.0 * 0.75

        begin
            tOperation = [
                DateTime("2022-01-01T00:30"),
                DateTime("2022-01-01T01:14"),
                DateTime("2022-01-01T01:32"),
                DateTime("2022-01-01T02:32:49"),
                DateTime("2022-01-01T02:50"),
                DateTime("2022-01-01T03:45"),
            ]

            irregularOperationIncomeMatches =
                OperationHistory(
                    tOperation,
                    ones(length(tOperation) - 1),
                    zeros(length(tOperation)),
                    ones(length(tOperation)),
                )[:powerKw] ⋅ VariableIntervalTimeSeries(
                    DateTime(2022, 1, 1):Minute(10):DateTime(2022, 1, 1, 4),
                    ones(24),
                ) ≈ 3.25

            @test irregularOperationIncomeMatches
        end
    end

    @testset "Energy Arbitrage" begin
        tOperation = [
            DateTime("2022-01-01T00:30"),
            DateTime("2022-01-01T01:14"),
            DateTime("2022-01-01T01:32"),
            DateTime("2022-01-01T02:32:49"),
            DateTime("2022-01-01T02:50"),
            DateTime("2022-01-01T03:45"),
        ]
        outputProgress = Progress(
            100,
            ScheduleHistory(
                DateTime(2022):Hour(1):DateTime(2022, 1, 1, 4),
                [0.5, 1.0, 1.0, 0],
            ),
            OperationHistory(
                tOperation,
                ones(length(tOperation) - 1),
                zeros(length(tOperation)),
                ones(length(tOperation)),
            ),
        )

        ucEA = EnergyArbitrage(
            FixedIntervalTimeSeries(DateTime(2022), Hour(1), [10.0, 20.0, 50.0, 30.0]),
        )

        @test calculate_net_benefit(outputProgress, ucEA) isa Float64
        @test calculate_metrics(outputProgress.schedule, outputProgress.operation, ucEA) isa
              AbstractVector
        @test use_case_charts(outputProgress.schedule, outputProgress.operation, ucEA) isa
              AbstractVector
    end

    @testset "Regulation/AGC" begin
        tOperation = DateTime(2022):Second(4):DateTime(2022, 1, 1, 3)
        outputProgress = Progress(
            100,
            ScheduleHistory(
                DateTime(2022):Hour(1):DateTime(2022, 1, 1, 3),
                [0.5, 1.0, 0],
                [0.5, 0.4, 0.25, 0.2],
                [0.5, 0, 1.0],
            ),
            OperationHistory(
                tOperation,
                rand(length(tOperation) - 1),
                zeros(length(tOperation)),
                ones(length(tOperation)),
            ),
        )

        ucReg = Regulation(
            FixedIntervalTimeSeries(DateTime(2022), Second(4), rand(3 * 900) .* 2 .- 1),
            FixedIntervalTimeSeries(
                DateTime(2022),
                Hour(1),
                [
                    RegulationPricePoint(30.0, 1.0),
                    RegulationPricePoint(10.0, 1.0),
                    RegulationPricePoint(50.0, 2.0),
                ],
            ),
            0.9,
        )

        mileagePerHour = sum(
            abs.(diff(reshape(get_values(ucReg.AGCSignalPu).vec, 900, :); dims = 1));
            dims = 1,
        )[:]

        @test calculate_net_benefit(outputProgress, ucReg) ≈
              (0.5 * (30 + 1 * mileagePerHour[1]) + 1 * (50 + 2 * mileagePerHour[3])) *
              ucReg.performanceScore
        @test calculate_metrics(
            outputProgress.schedule,
            outputProgress.operation,
            ucReg,
        ) isa AbstractVector
        @test use_case_charts(outputProgress.schedule, outputProgress.operation, ucReg) isa
              AbstractVector
    end

    @testset "Demand Charge Reduction" begin
        ucDCR = DemandChargeReduction(
            EnergyStorageUseCases.FlatDemandChargeRateStructure(10),
            FixedIntervalTimeSeries(DateTime(2023), Minute(15), collect(1:12)),
        )
        @test demand_charge(
            ucDCR,
            FixedIntervalTimeSeries(DateTime(2023), Hour(1), zeros(3)),
        ) == 120

        ucDCR = DemandChargeReduction(
            EnergyStorageUseCases.FlatDemandChargeRateStructure(10),
            FixedIntervalTimeSeries(DateTime(2023), Minute(5), collect(1:24)),
        )
        @test demand_charge(
            ucDCR,
            FixedIntervalTimeSeries(DateTime(2023), Hour(1), zeros(2)),
        ) == 230
    end
end