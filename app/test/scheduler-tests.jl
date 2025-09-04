using CtrlEvalEngine:
    ScheduleHistory, OperationHistory, Progress, power, VariableIntervalTimeSeries
using CtrlEvalEngine.EnergyStorageSimulators:
    LiIonBattery, LFP_LiIonBatterySpecs, LiIonBatteryStates, p_max
using CtrlEvalEngine.EnergyStorageUseCases:
    UseCase, EnergyArbitrage, Regulation, RegulationPricePoint
using CtrlEvalEngine.EnergyStorageScheduling:
    schedule,
    EvolutionaryScheduler,
    GeneticAlgorithm,
    OptScheduler,
    ManualScheduler,
    RLScheduler,
    RuleBasedScheduler,
    TimeOfUseRuleSet,
    TimeOfUseScheduler
using Dates

t = now()

progress = Progress(
    5.0,
    ScheduleHistory([t], Float64[], Float64[0.5], Float64[]),
    OperationHistory([t], Float64[], Float64[0.5], Float64[1.0]),
)

@testset "Manual Scheduler" begin
    ess = LiIonBattery(
        LFP_LiIonBatterySpecs(500, 1000, 0.85, 2000),
        LiIonBatteryStates(0.5, 0),
    )
    manSched = ManualScheduler([3.6, 65.2, 87.9, 2.4, 91.7], floor(now(), Hour(1)), Hour(1))
    sched = schedule(ess, manSched, Nothing, floor(now(), Hour(1)), progress)
    @test sched.powerKw == [3.6, 65.2, 87.9, 2.4, 91.7]
    @test sched.tStart == floor(now(), Hour(1))
    @test sched.resolution == Hour(1)
end

@testset "Time of Use Scheduler" begin
    ess = LiIonBattery(
        LFP_LiIonBatterySpecs(500, 1000, 0.85, 2000),
        LiIonBatteryStates(0.5, 0),
    )
    tStart = floor(now(), Hour(1))
    useCases = UseCase[EnergyArbitrage(
        VariableIntervalTimeSeries(
            range(tStart; step = Hour(1), length = 6),
            [0.2, 0.5, 0.9, 0.4, 0.1],
        ),
    )]
    scheduler = TimeOfUseScheduler(
        Hour(1),
        Hour(5),
        TimeOfUseRuleSet([0.4, 0.7], [90, nothing, 10]),
    )
    sched = schedule(ess, scheduler, useCases, floor(now(), Hour(1)), progress)
    @test sched.powerKw == [-433.86091563731236, -0.0, 500.0, -0.0, -500.0]
end

@testset "Optimization Scheduler" begin
    ess = LiIonBattery(
        LFP_LiIonBatterySpecs(500, 1000, 0.85, 2000),
        LiIonBatteryStates(0.5, 0),
    )
    optScheduler = OptScheduler(Hour(1), Hour(4), 4)
    tStart = floor(now(), Hour(1))
    useCases = UseCase[EnergyArbitrage(
        VariableIntervalTimeSeries(
            range(tStart; step = Hour(1), length = 5),
            [10, 20, 1, 10],
        ),
    )]
    sVar = schedule(ess, optScheduler, useCases, tStart, progress)
    @test sVar.powerKw[2] > sVar.powerKw[3]

    useCases =
        UseCase[EnergyArbitrage(FixedIntervalTimeSeries(tStart, Hour(1), [10, 20, 1, 10]))]
    sFix = schedule(ess, optScheduler, useCases, tStart, progress)
    @test all(sVar.powerKw .== sFix.powerKw)

    # Sub-hourly resolution
    optScheduler = OptScheduler(Minute(30), Hour(4), 8)
    sSubHourly = schedule(ess, optScheduler, useCases, tStart, progress)
    @test all(sum(reshape(sSubHourly.powerKw, 2, :); dims = 1)[:] ./ 2 .≈ sFix.powerKw)

    optScheduler = OptScheduler(Minute(15), Hour(4), 16)
    sSubHourly = schedule(ess, optScheduler, useCases, tStart, progress)
    @test all(sum(reshape(sSubHourly.powerKw, 4, :); dims = 1)[:] ./ 4 .≈ sFix.powerKw)

    # OptScheduler with regulation
    useCases = UseCase[
        EnergyArbitrage(FixedIntervalTimeSeries(tStart, Hour(1), [10, 20, 1, 10])),
        Regulation(
            FixedIntervalTimeSeries(tStart, Second(4), zeros(15 * 60 * 4)),
            FixedIntervalTimeSeries(
                tStart,
                Hour(1),
                [
                    RegulationPricePoint(5.3, 3),
                    RegulationPricePoint(20.1, 4),
                    RegulationPricePoint(12, 2),
                    RegulationPricePoint(10, 3.6),
                ],
            ),
            1.0,
        ),
    ]

    optScheduler = OptScheduler(Hour(1), Hour(4), 8)
    sReg = schedule(ess, optScheduler, useCases, tStart, progress)
    @test length(sReg.powerKw) == 4

    optScheduler2 =
        OptScheduler(Hour(1), Hour(4), 4; powerLimitPu = 0.5, minNetLoadKw = -100)
    s2 = schedule(ess, optScheduler2, useCases, tStart, progress)
    @test all(abs.(s2.powerKw) .≤ p_max(ess.specs) * 0.5)
    @test all(s2.powerKw .≤ 100)
end

@testset "Rule-based Scheduler" begin
    ess = LiIonBattery(
        LFP_LiIonBatterySpecs(500, 1000, 0.85, 2000),
        LiIonBatteryStates(0.5, 0),
    )

    ruleBasedScheduler = RuleBasedScheduler(Hour(1), Hour(24), Dict())
    tStart = floor(now(), Hour(1))
    useCases = UseCase[EnergyArbitrage(
        VariableIntervalTimeSeries(
            range(tStart; step = Hour(6), length = 6),
            [10, 20, 1, 10, 5],
        ),
    )]
    sRB = schedule(ess, ruleBasedScheduler, useCases, tStart, progress)
    @test length(sRB.powerKw) == 24
end

@testset "Genetic Algorithm Scheduler" begin
    tStart = floor(now(), Hour(1))
    ess = LiIonBattery(
        LFP_LiIonBatterySpecs(500, 1000, 0.85, 2000),
        LiIonBatteryStates(0.5, 0),
    )
    useCases = UseCase[EnergyArbitrage(
        VariableIntervalTimeSeries(
            range(tStart; step = Hour(6), length = 6),
            [10, 20, 1, 10, 5],
        ),
    )]
    scheduler = EvolutionaryScheduler(Hour(1), Hour(5), GeneticAlgorithm(
        100,        # populationSize::Int  # The size of the population
        0.8,        # crossoverRate::Float64 # The fraction of the population at the next generation, not including elite children, that is created by the crossover function.
        0.1,        # mutationRate:: Float64 # Probability of chromosome to be mutated
        0.0,        # ɛ::Integer # Positive integer specifies how many individuals in the current generation are guaranteed to survive to the next generation. Floating number specifies fraction of population.
        ("tournament", (2,)),   # selection::String # Selection function (default: tournament)
        "genop",       # crossover::String # Crossover function (default: genop)
        "genop",    # mutation::String # Mutation function (default: genop)
        [("AbsDiff", (1e-12,))]  # metrics::Vector{String}  # A collection of convergence metrics.
    ))
    println(scheduler)
    sched = schedule(ess, scheduler, useCases, floor(now(), Hour(1)))
    @test sched.powerKw <= [-433.86091563731236, -0.0, 500.0, -0.0, -500.0]  # TODO: removed sum() from second vector. Is this the right test now?
end