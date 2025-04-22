using Dates
using LinearAlgebra

@testset "Fixed Interval" begin
    @testset "Period Series Extraction" begin
        ts1 = FixedIntervalPeriodTimeSeries(DateTime(2022), Hour(1), collect(1:5))
        ts2 = extract(ts1, DateTime(2022, 1, 1, 2), DateTime(2022, 1, 1, 4))
        @test ts2 isa FixedIntervalPeriodTimeSeries
        @test all(ts2.value .== [3, 4])

        ts3 = extract(ts1, DateTime(2022, 1, 1, 1, 30), DateTime(2022, 1, 1, 4, 30))
        @test ts3 isa VariableIntervalPeriodTimeSeries
        @test start_time(ts3) == DateTime(2022, 1, 1, 1, 30)
        @test end_time(ts3) == DateTime(2022, 1, 1, 4, 30)
        @test all(ts3.value .== 2:5)
    end

    @testset "Point Series Extraction" begin
        ts1 = FixedIntervalPointTimeSeries(DateTime(2022), Hour(1), collect(1:5))

        # Both ends on grid
        ts2a = extract(ts1, DateTime(2022, 1, 1, 2), DateTime(2022, 1, 1, 4))
        @test ts2a isa FixedIntervalPointTimeSeries
        @test all(ts2a.value .== [3, 4, 5])

        # t2 passes end time
        ts2b = extract(ts1, DateTime(2022, 1, 1, 2), DateTime(2022, 1, 1, 4, 30))
        @test ts2b isa FixedIntervalPointTimeSeries
        @test end_time(ts2b) == DateTime(2022, 1, 1, 4)
        @test all(ts2b.value .== [3, 4, 5])

        # No time overlap
        ts2c = extract(ts1, DateTime(2022, 1, 1, 5), DateTime(2022, 1, 1, 6, 30))
        @test ts2c isa FixedIntervalPeriodTimeSeries
        @test length(ts2c) == 0

        # Both ends off grid
        ts3 = extract(ts1, DateTime(2022, 1, 1, 1, 15), DateTime(2022, 1, 1, 3, 30))
        @test ts3 isa VariableIntervalPointTimeSeries
        @test start_time(ts3) == DateTime(2022, 1, 1, 1, 15)
        @test end_time(ts3) == DateTime(2022, 1, 1, 3, 30)
        @test all(
            ts3.t .== [
                DateTime(2022, 1, 1, 1, 15),
                DateTime(2022, 1, 1, 2),
                DateTime(2022, 1, 1, 3),
                DateTime(2022, 1, 1, 3, 30),
            ],
        )
        @test all(ts3.value .== [2.25, 3, 4, 4.5])

        # t1 off grid
        ts4 = extract(ts1, DateTime(2022, 1, 1, 1, 15), DateTime(2022, 1, 1, 3))
        @test ts4 isa VariableIntervalPointTimeSeries
        @test start_time(ts4) == DateTime(2022, 1, 1, 1, 15)
        @test end_time(ts4) == DateTime(2022, 1, 1, 3)
        @test all(
            ts4.t .== [
                DateTime(2022, 1, 1, 1, 15),
                DateTime(2022, 1, 1, 2),
                DateTime(2022, 1, 1, 3),
            ],
        )
        @test all(ts4.value .== [2.25, 3, 4])

        # t2 off grid
        ts5 = extract(ts1, DateTime(2022, 1, 1, 1), DateTime(2022, 1, 1, 3, 30))
        @test ts5 isa VariableIntervalPointTimeSeries
        @test start_time(ts5) == DateTime(2022, 1, 1, 1)
        @test end_time(ts5) == DateTime(2022, 1, 1, 3, 30)
        @test all(
            ts5.t .== [
                DateTime(2022, 1, 1, 1),
                DateTime(2022, 1, 1, 2),
                DateTime(2022, 1, 1, 3),
                DateTime(2022, 1, 1, 3, 30),
            ],
        )
        @test all(ts5.value .== [2, 3, 4, 4.5])
    end

    @testset "Integral Operations" begin
        ts1 = FixedIntervalTimeSeries(DateTime(2023), Hour(1), collect(1:5))
        @test integrate(ts1) == sum(1:5)
        @test integrate(ts1, DateTime(2023, 1, 1, 2), DateTime(2023, 1, 1, 5)) == sum(3:5)
        @test mean(ts1) == 3
        @test mean(ts1, DateTime(2023, 1, 1, 1), DateTime(2023, 1, 1, 3)) == 2.5

        ts2 = FixedIntervalTimeSeries(DateTime(2023), Minute(15), collect(1:5))
        @test integrate(ts2) == sum(1:5) / 4
        @test integrate(ts2, DateTime(2023, 1, 1, 1), DateTime(2023, 1, 1, 5)) == 5 / 4
        @test mean(ts2) == 3
        @test mean(ts2, DateTime(2023, 1, 1, 1), DateTime(2023, 1, 1, 3)) == 5 / 4 / 2
    end
end

@testset "Variable Interval" begin
    @testset "Extraction" begin
        ts1 = VariableIntervalTimeSeries(
            DateTime(2022):Hour(1):DateTime(2022, 1, 1, 5),
            collect(1:5),
        )

        ts2 = extract(ts1, DateTime(2022, 1, 1, 1), DateTime(2022, 1, 1, 4))
        @test ts2 isa VariableIntervalTimeSeries
        @test all(
            timestamps(ts2) .== [
                DateTime(2022, 1, 1, 1),
                DateTime(2022, 1, 1, 2),
                DateTime(2022, 1, 1, 3),
                DateTime(2022, 1, 1, 4),
            ],
        )
        @test all(ts2.value .== 2:4)

        ts3 = extract(ts1, DateTime(2022, 1, 1, 1, 30), DateTime(2022, 1, 1, 4, 30))
        @test ts3 isa VariableIntervalTimeSeries
        @test all(
            timestamps(ts3) .== [
                DateTime(2022, 1, 1, 1, 30),
                DateTime(2022, 1, 1, 2),
                DateTime(2022, 1, 1, 3),
                DateTime(2022, 1, 1, 4),
                DateTime(2022, 1, 1, 4, 30),
            ],
        )
        @test all(ts3.value .== 2:5)
    end

    @testset "Binary Operations" begin
        t = [
            DateTime("2022-01-01T00:30"),
            DateTime("2022-01-01T01:14"),
            DateTime("2022-01-01T01:32"),
            DateTime("2022-01-01T02:32:49"),
            DateTime("2022-01-01T02:50"),
            DateTime("2022-01-01T03:45"),
        ]

        irregularIntervalMatches =
            VariableIntervalTimeSeries(t, ones(length(t) - 1)) ⋅
            VariableIntervalTimeSeries(
                DateTime(2022, 1, 1):Minute(10):DateTime(2022, 1, 1, 4),
                ones(24),
            ) ≈ 3.25

        @test irregularIntervalMatches

        tsSum =
            VariableIntervalTimeSeries(
                [DateTime(2023), DateTime(2023, 1, 1, 1), DateTime(2023, 1, 1, 1, 30)],
                [2, 3],
            ) + VariableIntervalTimeSeries(
                [
                    DateTime(2023, 1, 1, 0, 20),
                    DateTime(2023, 1, 1, 0, 50),
                    DateTime(2023, 1, 1, 1, 15),
                    DateTime(2023, 1, 1, 2, 30),
                ],
                [2, 3, 5],
            )
        @test all(
            timestamps(tsSum) .== [
                DateTime(2023),
                DateTime(2023, 1, 1, 0, 20),
                DateTime(2023, 1, 1, 0, 50),
                DateTime(2023, 1, 1, 1),
                DateTime(2023, 1, 1, 1, 15),
                DateTime(2023, 1, 1, 1, 30),
                DateTime(2023, 1, 1, 2, 30),
            ],
        )
        @test all(get_values(tsSum) .== [2, 4, 5, 6, 8, 5])

        tsProd =
            VariableIntervalTimeSeries(
                [DateTime(2023), DateTime(2023, 1, 1, 1), DateTime(2023, 1, 1, 1, 30)],
                [2, 3],
            ) * VariableIntervalTimeSeries(
                [
                    DateTime(2023, 1, 1, 0, 20),
                    DateTime(2023, 1, 1, 0, 50),
                    DateTime(2023, 1, 1, 1, 15),
                    DateTime(2023, 1, 1, 2, 30),
                ],
                [2, 3, 5],
            )
        @test all(
            timestamps(tsProd) .== [
                DateTime(2023),
                DateTime(2023, 1, 1, 0, 20),
                DateTime(2023, 1, 1, 0, 50),
                DateTime(2023, 1, 1, 1),
                DateTime(2023, 1, 1, 1, 15),
                DateTime(2023, 1, 1, 1, 30),
                DateTime(2023, 1, 1, 2, 30),
            ],
        )
        @test all(get_values(tsProd) .== [0, 4, 6, 9, 15, 0])
    end

    @testset "Integral Operations" begin
        ts1 = VariableIntervalTimeSeries(
            [
                DateTime(2023, 1, 1, 0, 20),
                DateTime(2023, 1, 1, 0, 50),
                DateTime(2023, 1, 1, 1, 15),
                DateTime(2023, 1, 1, 2, 30),
            ],
            [2, 3, 5],
        )
        @test integrate(ts1) ≈ 2 * 0.5 + 3 * 25 / 60 + 5 * 75 / 60
        @test integrate(ts1, DateTime(2023, 1, 1, 1), DateTime(2023, 1, 1, 5)) ≈
              3 * 15 / 60 + 5 * 75 / 60
        @test mean(ts1) ≈ (2 * 30 + 3 * 25 + 5 * 75) / 130
        @test mean(ts1, DateTime(2023, 1, 1, 1), DateTime(2023, 1, 1, 3)) ≈
              (3 * 15 + 5 * 75) / 120
        tsMean = mean(ts1, [DateTime(2023, 1, 1, 1), DateTime(2023, 1, 1, 3)])
        @test tsMean isa VariableIntervalTimeSeries
        @test tsMean.value[1] ≈ (3 * 15 + 5 * 75) / 120

        m = (2 * 30 + 3 * 25 + 5 * 75) / 130
        @test std(ts1) ≈ sqrt(((2 - m)^2 * 30 + (3 - m)^2 * 25 + (5 - m)^2 * 75) / 130)
    end
end

@testset "RepeatedTimeSeries" begin
    @testset "Construction" begin
        ts = RepeatedTimeSeries(
            FixedIntervalTimeSeries(DateTime(2022), Hour(1), collect(1:5)),
            DateTime(2022, 1, 1, 2),
            DateTime(2022, 1, 1, 7),
        )
        @test ts.iStart == 3
        @test ts.iEnd == 8
        @test start_time(ts) == DateTime(2022, 1, 1, 2)
        @test end_time(ts) == DateTime(2022, 1, 1, 7)

        ts = RepeatedTimeSeries(
            FixedIntervalTimeSeries(DateTime(2022), Hour(1), collect(1:5)),
            DateTime(2021, 12, 31, 2, 50),
            DateTime(2022, 1, 1, 7, 30),
        )
        @test start_time(ts) == DateTime(2021, 12, 31, 2, 50)
        @test end_time(ts) == DateTime(2022, 1, 1, 7, 30)
    end
    @testset "Extraction" begin
        ts1 = RepeatedTimeSeries(
            FixedIntervalTimeSeries(DateTime(2022), Hour(1), collect(1:5)),
            1,
            12,
        )
        @test start_time(ts1) == DateTime(2022)
        @test end_time(ts1) == DateTime(2022, 1, 1, 12)
        ts2 = extract(ts1, DateTime(2022, 1, 1, 2), DateTime(2022, 1, 1, 4))
        @test ts2 isa RepeatedTimeSeries
        @test all(get_values(ts2) .== [3, 4])

        ts3 = extract(ts1, DateTime(2022, 1, 1, 1, 30), DateTime(2022, 1, 1, 4, 30))
        @test ts3 isa RepeatedTimeSeries
        @test start_time(ts3) == DateTime(2022, 1, 1, 1, 30)
        @test end_time(ts3) == DateTime(2022, 1, 1, 4, 30)
        @test all(get_values(ts3) .== 2:5)

        ts4 = RepeatedTimeSeries(
            FixedIntervalTimeSeries(DateTime(2022), Hour(1), collect(1:5)),
            -3,
            Minute(20),
            4,
            -Minute(40),
        )
        @test start_time(ts4) == DateTime(2021, 12, 31, 20, 20)
        @test end_time(ts4) == DateTime(2022, 1, 1, 3, 20)
        ts5 = extract(ts4, DateTime(2022, 1, 1, 1, 30), DateTime(2022, 1, 1, 4, 30))
        @test start_time(ts5) == DateTime(2022, 1, 1, 1, 30)
        @test end_time(ts5) == DateTime(2022, 1, 1, 3, 20)
    end

    @testset "Integral Operations" begin
        ts1 = RepeatedTimeSeries(
            FixedIntervalTimeSeries(DateTime(2023), Hour(1), collect(1:5)),
            1,
            12,
        )
        @test integrate(ts1) == sum(1:5) * 2 + sum(1:2)
        @test integrate(ts1, DateTime(2023, 1, 1, 2), DateTime(2023, 1, 1, 5)) == sum(3:5)
        @test mean(ts1) == (sum(1:5) * 2 + sum(1:2)) / 12
        @test mean(ts1, DateTime(2023, 1, 1, 1), DateTime(2023, 1, 1, 3)) == 2.5

        ts2 = RepeatedTimeSeries(
            FixedIntervalTimeSeries(DateTime(2023), Minute(15), collect(1:5)),
            1,
            12,
        )
        @test integrate(ts2) == (sum(1:5) * 2 + sum(1:2)) / 4
        @test integrate(ts2, DateTime(2023, 1, 1, 1), DateTime(2023, 1, 1, 5)) ==
              (5 + 1 + 2 + 3 + 4 + 5 + 1 + 2) / 4
        @test mean(ts2) == (sum(1:5) * 2 + sum(1:2)) / 12
        @test mean(ts2, DateTime(2023, 1, 1, 1), DateTime(2023, 1, 1, 3)) ==
              (5 + 1 + 2 + 3 + 4 + 5 + 1 + 2) / 4 / 2
    end
end