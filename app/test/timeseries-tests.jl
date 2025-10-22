using Dates
using LinearAlgebra

@testset "Series" begin
    @testset "Period Series" begin
        s1 = PeriodSeries(0.0:3)
        @test length(s1) == 4
        @test s1[2] == 1
        @test s1[2:4] isa PeriodSeries
        @test s1[2:4].vec == 1:3
        @test s1[2.3] == 2
        @test s1[0.0] == 0
        @test s1[0:0.5:2] == [0, 0, 1, 1, 2]

        s2 = extract(s1, 1.3, 2.7)
        @test s2 isa PeriodSeries
        @test s2.vec == [1, 2]

        s3 = extract(s1, 1.3, 3)
        @test s3 isa PeriodSeries
        @test s3.vec == [1, 2]

        s4 = upsample(s1, 2)
        @test s4 isa PeriodSeries
        @test length(s4) == 8
        @test s4.vec == [0, 0, 1, 1, 2, 2, 3, 3]
    end

    @testset "Point Series" begin
        s1 = PointSeries(0.0:4)
        @test length(s1) == 4
        @test s1[2] == (1, 2)
        @test s1[2:4] isa PointSeries
        @test s1[2:4].vec == 1:4
        @test s1[2.3] ≈ 2.3
        @test s1[0.0] ≈ 0.0
        @test s1[0:0.5:2] == 0:0.5:2

        s2 = extract(s1, 0.3, 2.7)
        @test s2 isa PointSeries
        @test s2.vec == [0.3, 1, 2, 2.7]

        s3 = extract(s1, 1.3, 3)
        @test s3 isa PointSeries
        @test s3.vec == [1.3, 2, 3]

        s4 = upsample(s1, 2)
        @test s4 isa PointSeries
        @test length(s4) == 8
        @test s4.vec == [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0]
    end
end

@testset "Fixed Interval" begin
    @testset "Period Series Extraction" begin
        ts1 = FixedIntervalTimeSeries(DateTime(2022), Hour(1), PeriodSeries(collect(1:5)))

        # Both ends on grid
        ts2 = extract(ts1, DateTime(2022, 1, 1, 2), DateTime(2022, 1, 1, 4))
        @test ts2 isa FixedIntervalTimeSeries
        @test ts2.value isa PeriodSeries
        @test ts2.value.vec == [3, 4]

        # Both ends off grid
        ts3 = extract(ts1, DateTime(2022, 1, 1, 1, 30), DateTime(2022, 1, 1, 4, 30))
        @test ts3 isa VariableIntervalTimeSeries
        @test ts3.value isa PeriodSeries
        @test start_time(ts3) == DateTime(2022, 1, 1, 1, 30)
        @test end_time(ts3) == DateTime(2022, 1, 1, 4, 30)
        @test ts3.value.vec == 2:5

        # t1 off grid
        ts4 = extract(ts1, DateTime(2022, 1, 1, 1, 15), DateTime(2022, 1, 1, 3))
        @test ts4 isa VariableIntervalTimeSeries
        @test start_time(ts4) == DateTime(2022, 1, 1, 1, 15)
        @test end_time(ts4) == DateTime(2022, 1, 1, 3)
        @test ts4.t == [
            DateTime(2022, 1, 1, 1, 15),
            DateTime(2022, 1, 1, 2),
            DateTime(2022, 1, 1, 3),
        ]
        @test ts4.value.vec == [2, 3]

        # t2 off grid
        ts5 = extract(ts1, DateTime(2022, 1, 1, 1), DateTime(2022, 1, 1, 3, 30))
        @test ts5 isa VariableIntervalTimeSeries
        @test start_time(ts5) == DateTime(2022, 1, 1, 1)
        @test end_time(ts5) == DateTime(2022, 1, 1, 3, 30)
        @test ts5.t == [
            DateTime(2022, 1, 1, 1),
            DateTime(2022, 1, 1, 2),
            DateTime(2022, 1, 1, 3),
            DateTime(2022, 1, 1, 3, 30),
        ]
        @test ts5.value.vec == [2, 3, 4]
    end

    @testset "Point Series Extraction" begin
        ts1 = FixedIntervalTimeSeries(DateTime(2022), Hour(1), PointSeries(1:5))

        # Both ends on grid
        ts2a = extract(ts1, DateTime(2022, 1, 1, 2), DateTime(2022, 1, 1, 4))
        @test ts2a isa FixedIntervalTimeSeries
        @test ts2a.value isa PointSeries
        @test ts2a.value.vec == [3, 4, 5]

        # t2 passes end time
        ts2b = extract(ts1, DateTime(2022, 1, 1, 2), DateTime(2022, 1, 1, 4, 30))
        @test ts2b isa FixedIntervalTimeSeries
        @test end_time(ts2b) == DateTime(2022, 1, 1, 4)
        @test ts2b.value.vec == [3, 4, 5]

        # No time overlap
        ts2c = extract(ts1, DateTime(2022, 1, 1, 5), DateTime(2022, 1, 1, 6, 30))
        @test ts2c isa FixedIntervalTimeSeries
        @test length(ts2c) == 0

        # Both ends off grid
        ts3 = extract(ts1, DateTime(2022, 1, 1, 1, 15), DateTime(2022, 1, 1, 3, 30))
        @test ts3 isa VariableIntervalTimeSeries
        @test start_time(ts3) == DateTime(2022, 1, 1, 1, 15)
        @test end_time(ts3) == DateTime(2022, 1, 1, 3, 30)
        @test ts3.t == [
            DateTime(2022, 1, 1, 1, 15),
            DateTime(2022, 1, 1, 2),
            DateTime(2022, 1, 1, 3),
            DateTime(2022, 1, 1, 3, 30),
        ]
        @test ts3.value.vec == [2.25, 3, 4, 4.5]

        # t1 off grid
        ts4 = extract(ts1, DateTime(2022, 1, 1, 1, 15), DateTime(2022, 1, 1, 3))
        @test ts4 isa VariableIntervalTimeSeries
        @test start_time(ts4) == DateTime(2022, 1, 1, 1, 15)
        @test end_time(ts4) == DateTime(2022, 1, 1, 3)
        @test ts4.t == [
            DateTime(2022, 1, 1, 1, 15),
            DateTime(2022, 1, 1, 2),
            DateTime(2022, 1, 1, 3),
        ]
        @test ts4.value.vec == [2.25, 3, 4]

        # t2 off grid
        ts5 = extract(ts1, DateTime(2022, 1, 1, 1), DateTime(2022, 1, 1, 3, 30))
        @test ts5 isa VariableIntervalTimeSeries
        @test start_time(ts5) == DateTime(2022, 1, 1, 1)
        @test end_time(ts5) == DateTime(2022, 1, 1, 3, 30)
        @test ts5.t == [
            DateTime(2022, 1, 1, 1),
            DateTime(2022, 1, 1, 2),
            DateTime(2022, 1, 1, 3),
            DateTime(2022, 1, 1, 3, 30),
        ]
        @test ts5.value.vec == [2, 3, 4, 4.5]
    end

    @testset "Period Series Integral & Mean" begin
        ts1 = FixedIntervalTimeSeries(DateTime(2023), Hour(1), PeriodSeries(1:5))
        @test integrate(ts1) == sum(1:5)
        @test integrate(ts1, DateTime(2023, 1, 1, 2), DateTime(2023, 1, 1, 5)) == sum(3:5)
        @test mean(ts1) == 3
        @test mean(ts1, DateTime(2023, 1, 1, 1), DateTime(2023, 1, 1, 3)) == 2.5

        ts2 = FixedIntervalTimeSeries(DateTime(2023), Minute(15), PeriodSeries(1:5))
        @test integrate(ts2) == sum(1:5) / 4
        @test integrate(ts2, DateTime(2023, 1, 1, 1), DateTime(2023, 1, 1, 5)) == 5 / 4
        @test mean(ts2) == 3
        @test mean(ts2, DateTime(2023, 1, 1, 1), DateTime(2023, 1, 1, 3)) == 5 / 4 / 2
    end

    @testset "Point Series Integral & Mean" begin
        ts1 = FixedIntervalTimeSeries(DateTime(2023), Hour(1), PointSeries(1:5))
        @test integrate(ts1) == 4 + (5 - 1) * 4 / 2
        @test integrate(ts1, DateTime(2023, 1, 1, 2), DateTime(2023, 1, 1, 4)) ==
              3 * 2 + (5 - 3) * 2 / 2
        @test mean(ts1) == (1 + 5) / 2
        @test mean(ts1, DateTime(2023, 1, 1, 1), DateTime(2023, 1, 1, 3)) == (2 + 4) / 2

        ts2 = FixedIntervalTimeSeries(DateTime(2023), Minute(15), PointSeries(1:5))
        @test integrate(ts2) == (4 + (5 - 1) * 4 / 2) / 4
        @test integrate(ts2, DateTime(2023, 1, 1, 0, 15), DateTime(2023, 1, 1, 4)) ==
              (2 * 3 + (5 - 2) * 3 / 2) / 4
        @test mean(ts2) == (1 + 5) / 2
        @test mean(ts2, DateTime(2023, 1, 1, 0, 15), DateTime(2023, 1, 1, 2, 15)) ==
              (2 * 3 + (5 - 2) * 3 / 2) / 4 / 2

        ts3 = FixedIntervalTimeSeries(DateTime(2023), Hour(1), PointSeries([0, 1, 1, 3, 2]))
        @test integrate(ts3) == 0.5 + 1 + 2 + 2.5
        @test integrate(ts3, DateTime(2023, 1, 1, 1), DateTime(2023, 1, 1, 3)) == 1 + 2
        @test mean(ts3) == (0.5 + 1 + 2 + 2.5) / 4
        @test mean(ts3, DateTime(2023, 1, 1, 1), DateTime(2023, 1, 1, 3)) == 3 / 2
    end
end

@testset "Variable Interval" begin
    @testset "Extraction" begin
        ts1 = VariableIntervalTimeSeries(
            DateTime(2022):Hour(1):DateTime(2022, 1, 1, 5),
            PeriodSeries(1:5),
        )

        ts2 = extract(ts1, DateTime(2022, 1, 1, 1), DateTime(2022, 1, 1, 4))
        @test ts2 isa VariableIntervalTimeSeries
        @test timestamps(ts2) == [
            DateTime(2022, 1, 1, 1),
            DateTime(2022, 1, 1, 2),
            DateTime(2022, 1, 1, 3),
            DateTime(2022, 1, 1, 4),
        ]
        @test ts2.value.vec == 2:4

        ts3 = extract(ts1, DateTime(2022, 1, 1, 1, 30), DateTime(2022, 1, 1, 4, 30))
        @test ts3 isa VariableIntervalTimeSeries
        @test timestamps(ts3) == [
            DateTime(2022, 1, 1, 1, 30),
            DateTime(2022, 1, 1, 2),
            DateTime(2022, 1, 1, 3),
            DateTime(2022, 1, 1, 4),
            DateTime(2022, 1, 1, 4, 30),
        ]
        @test ts3.value.vec == 2:5
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
            VariableIntervalTimeSeries(t, PeriodSeries(ones(length(t) - 1))) ⋅
            VariableIntervalTimeSeries(
                DateTime(2022, 1, 1):Minute(10):DateTime(2022, 1, 1, 4),
                PeriodSeries(ones(24)),
            ) ≈ 3.25

        @test irregularIntervalMatches

        tsSum =
            VariableIntervalTimeSeries(
                [DateTime(2023), DateTime(2023, 1, 1, 1), DateTime(2023, 1, 1, 1, 30)],
                PeriodSeries([2, 3]),
            ) + VariableIntervalTimeSeries(
                [
                    DateTime(2023, 1, 1, 0, 20),
                    DateTime(2023, 1, 1, 0, 50),
                    DateTime(2023, 1, 1, 1, 15),
                    DateTime(2023, 1, 1, 2, 30),
                ],
                PeriodSeries([2, 3, 5]),
            )
        @test timestamps(tsSum) == [
            DateTime(2023),
            DateTime(2023, 1, 1, 0, 20),
            DateTime(2023, 1, 1, 0, 50),
            DateTime(2023, 1, 1, 1),
            DateTime(2023, 1, 1, 1, 15),
            DateTime(2023, 1, 1, 1, 30),
            DateTime(2023, 1, 1, 2, 30),
        ]
        @test get_values(tsSum).vec == [2, 4, 5, 6, 8, 5]

        tsProd =
            VariableIntervalTimeSeries(
                [DateTime(2023), DateTime(2023, 1, 1, 1), DateTime(2023, 1, 1, 1, 30)],
                PeriodSeries([2, 3]),
            ) * VariableIntervalTimeSeries(
                [
                    DateTime(2023, 1, 1, 0, 20),
                    DateTime(2023, 1, 1, 0, 50),
                    DateTime(2023, 1, 1, 1, 15),
                    DateTime(2023, 1, 1, 2, 30),
                ],
                PeriodSeries([2, 3, 5]),
            )
        @test timestamps(tsProd) == [
            DateTime(2023),
            DateTime(2023, 1, 1, 0, 20),
            DateTime(2023, 1, 1, 0, 50),
            DateTime(2023, 1, 1, 1),
            DateTime(2023, 1, 1, 1, 15),
            DateTime(2023, 1, 1, 1, 30),
            DateTime(2023, 1, 1, 2, 30),
        ]
        @test get_values(tsProd).vec == [0, 4, 6, 9, 15, 0]
    end

    @testset "Period Series Integral & Mean" begin
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

        m = (2 * 30 + 3 * 25 + 5 * 75) / 130
        @test mean(ts1) ≈ m
        @test mean(ts1, DateTime(2023, 1, 1, 1), DateTime(2023, 1, 1, 3)) ≈
              (3 * 15 + 5 * 75) / 120
        tsMean = mean(ts1, [DateTime(2023, 1, 1, 1), DateTime(2023, 1, 1, 3)])
        @test tsMean isa VariableIntervalTimeSeries
        @test tsMean.value[1] ≈ (3 * 15 + 5 * 75) / 120

        @test std(ts1) ≈ sqrt(((2 - m)^2 * 30 + (3 - m)^2 * 25 + (5 - m)^2 * 75) / 130)
    end

    @testset "Point Series Integral & Mean" begin
        ts1 = VariableIntervalTimeSeries(
            [
                DateTime(2023, 1, 1, 0, 20),
                DateTime(2023, 1, 1, 0, 50),
                DateTime(2023, 1, 1, 1, 15),
                DateTime(2023, 1, 1, 2, 30),
            ],
            PointSeries([0, 2, 3, 5]),
        )
        @test integrate(ts1) ≈ 1 * 0.5 + 2.5 * 25 / 60 + 4 * 75 / 60
        @test integrate(ts1, DateTime(2023, 1, 1, 1), DateTime(2023, 1, 1, 5)) ≈
              ((1 - 17.5 / 25) * 2 + 17.5 / 25 * 3) * 15 / 60 + 4 * 75 / 60

        m = (1 * 30 + 2.5 * 25 + 4 * 75) / 130
        @test mean(ts1) ≈ m
        @test mean(ts1, DateTime(2023, 1, 1, 1), DateTime(2023, 1, 1, 3)) ≈
              (((1 - 17.5 / 25) * 2 + 17.5 / 25 * 3) * 15 + 4 * 75) / 120
        tsMean = mean(ts1, [DateTime(2023, 1, 1, 1), DateTime(2023, 1, 1, 3)])
        @test tsMean isa VariableIntervalTimeSeries
        @test tsMean.value[1] ≈ (((1 - 17.5 / 25) * 2 + 17.5 / 25 * 3) * 15 + 4 * 75) / 120

        # TODO: std for PointSeries is to be defined
        @test_throws MethodError std(ts1)
    end
end

@testset "RepeatedTimeSeries" begin
    @testset "Construction" begin
        ts = RepeatedTimeSeries(
            FixedIntervalTimeSeries(DateTime(2022), Hour(1), 1:5),
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
