using Dates
using Evolutionary
using CtrlEvalEngine.EnergyStorageScheduling: Scheduler

abstract type EvolutionaryAlgorithmOptions end

function get_option_func(optionType::String, name::String)
    if lowercase(optionType) == "selection"
        options = ["uniformranking", "randomoffset", "roulette", "tournament", "susinv", "best", "sus",
        "rouletteinv", "ranklinear", "random", "truncation", "permutation"]
        default = Evolutionary.tournament
    elseif lowercase(optionType) == "crossover"
        options = ["DC", "LX", "marriage", "SSX", "BINX", "SHFX", "PMX", "SBX", "IC", "BSX", "HX", "AX", "OX1", "TPX", "LC",
        "average", "genop", "UX", "WAX", "OX2", "EXPX", "MILX", "crosstree", "SPX", "POS"]
        default = Evolutionary.genop
    elseif lowercase(optionType) == "mutation"
        options = ["nop", "bitinversion", "BGA", "replace", "flip", "uniform", "PM", "shrink", "hoist", "differentiation", "PLM",
        "subtree", "swap2", "point", "shifting", "scramble", "cauchy", "insertion", "inversion", "MIPM", "gaussian"]
        default = Evolutionary.genop
    elseif lowercase(optionType) == "convergence"
        options = ["AbsDiff", "RelDiff", "GD"]
        default = Evolutionary.AbsDiff
    else
        return nothing  # TODO: Should this raise an exception or log a warning of some sort instead?
    return name in options ? getfield(Evolutionary, Symbol(name)) : default
    end
end

function get_option_func(optionType::String, name::String, params::Tuple{Any})
    func = get_option_func(optionType, name)
    return func(params...)
end

# TODO: Should this just be a function which loads the struct that already exists in Evolutionary?
struct GeneticAlgorithm <: EvolutionaryAlgorithmOptions
    populationSize::Int     # The size of the population
    crossoverRate::Float64  # The fraction of the population at the next generation, not including elite children, that is created by the crossover function.
    mutationRate:: Float64  # Probability of chromosome to be mutated
    ɛ::Real                 # Positive integer specifies how many individuals in the current generation are guaranteed to survive to the next generation. Floating number specifies fraction of population.
    selection::Tuple{String, Tuple{Any}}       # Selection function (default: tournament)
    crossover::String       # Crossover function (default: genop)
    mutation::String        # Mutation function (default: genop)
    metrics::Vector{Tuple{String, Tuple{Any}}} # A collection of convergence metrics.
end

# struct DifferentialEvolution <: EvolutionaryAlgorithmOptions
#     populationSize::Integer     # The size of the population
#     F::Real                     # The differentiation (mutation) scale factor (default: 0.9). It's usually defined in range F ∈ (0, 1+]
#     n::Integer                  # The number of differences used in the perturbation (default: 1)
#     selection::Real             # The selection strategy function (default: random)
#     recombination::String       # The recombination functions (default: BINX(0.5))
#     K::String                   # The recombination scale factor (default: 0.5*(F+1))
#     metrics::Vector{String}     # A collection of convergence metrics.
# end


# struct EvolutionStrategy <: EvolutionaryAlgorithmOptions
#     # TODO: Adjust to types that can be entered from a form.
#     initStrategy::AbstractStrategy  # An initial strategy description, (default: empty)
#     recombination::T1               # ES recombination function for population (default: `first`), see [Crossover](@ref)
#     srecombination::T2              # ES recombination function for strategies (default: `first`), see [Crossover](@ref)
#     mutation::T3                    # [Mutation](@ref) function for population (default: [`nop`](@ref))
#     smutation::T4                   # [Mutation](@ref) function for strategies (default: [`nop`](@ref))
#     μ::Integer                      # The number of parents
#     ρ::Integer                      # The mixing number, ρ ≤ μ, (i.e., the number of parents involved in the procreation of an offspring)
#     λ::Integer                      # The number of offspring
#     selection::Symbol               # The selection strategy `:plus` or `:comma` (default: `:plus`)
#     metrics::ConvergenceMetrics     # A collection of convergence metrics.
# end


# struct CovarianceMatrixAdaptationEvolutionStrategy <: EvolutionaryAlgorithmOptions
#     # TODO: Adjust to types that can be entered from a form.
#     μ::Int                      # `μ`/`mu` is the number of parents
#     λ::Int                      # `λ`/`lambda` is the number of offspring
#     c_1::T                      # `c_1` is a learning rate for the rank-one update of the covariance matrix update
#     c_c::T                      # `c_c` is a learning rate for cumulation for the rank-one update of the covariance matrix
#     c_μ::T                      # `c_mu` is a learning rate for the rank-``\\mu`` update of the covariance matrix update
#     c_σ::T                      # `c_sigma` is a learning rate for the cumulation for the step-size control
#     σ₀::T                       # `c_m` is the learning rate for the mean update, ``c_m \\leq 1``
#     cₘ::T                       # `σ0`/`sigma0` is the initial step size `σ`
#     wᵢ::Vector{T}               # `weights` are recombination weights, if the weights are set to ``1/\\mu`` then the *intermediate* recombination is activated.
#     metrics::ConvergenceMetrics # `metrics` is a collection of convergence metrics.
# end


# @kwdef struct GeneticProgramming <: EvolutionaryAlgorithmOptions
#     # TODO: Adjust to types that can be entered from a form.
#     populationSize::Integer = 50                                        # The size of the population
#     terminals::Dict{Terminal, Int} = Dict(:x=>1, rand=>1)               # A dictionary of terminals with their their corresponding dimensionality (This dictionary contains (Terminal, Int) pairs. The terminals can be any symbols (variables), constat values, or 0-arity functions.)
#     functions::Dict{Function, Int} = Dict( f=>2 for f in [+,-,*,pdiv] ) # A collection of functions with their corresponding arity. (This dictionary contains (Function, Int) pairs)
#     mindepth::Int = 0                                                   # Minimal depth of the expression (default: 0)
#     maxdepth::Int = 3                                                   # Maximal depth of the expression (default: 3)
#     crossover::Function = crosstree                                     # A crossover function (default: subtree)
#     mutation::Function = subtree                                        # A mutation function (default: crosstree)
#     selection::Function = tournament(2)                                 # 
#     crossoverRate::Real = 0.9                                           # 
#     mutationRate::Real = 0.1                                            # 
#     initialization::Symbol = :grow                                      # A strategy for population initialization (default: :grow) (Possible values: :grow and :full)
#     simplify::Union{Nothing, Function} = nothing                        # An expression simplification function (default: :nothing)
#     metrics::ConvergenceMetrics = ConvergenceMetric[AbsDiff(1e-5)]      #
# end


# struct NonDominatedSortingGeneticAlgorithm <: EvolutionaryAlgorithmOptions
#     # TODO: Adjust to types that can be entered from a form.
#     populationSize::Int         # The size of the population
#     crossoverRate::Float64      # The fraction of the population at the next generation, that is created by the crossover function
#     mutationRate::Float64       # Probability of chromosome to be mutated
#     selection::String           # Selection function (default: tournament)
#     crossover::String           # Crossover function (default: SBX)
#     mutation::String            # Mutation function (default: PLM)
#     metrics::ConvergenceMetrics # A collection of convergence metrics.
# end

# struct EvolutionaryScheduler{EvolutionaryAlgorithmOptions} <: Scheduler
#     resolution::Dates.Period
#     interval::Dates.Period
#     # individual_length::Int64 = Int64(floor(interval / resolution))
#     algorithmOptions::EvolutionaryAlgorithmOptions
#     algorithm::Type{<:Evolutionary.AbstractOptimizer}
# end

struct EvolutionaryScheduler{Optimizer <: Evolutionary.AbstractOptimizer} <: Scheduler
    resolution::Dates.Period
    interval::Dates.Period
    optimizer::Optimizer
end

function EvolutionaryScheduler(resolution::Dates.Period, interval::Dates.Period, algorithmOptions::EvolutionaryAlgorithmOptions)
    if algorithmOptions isa GeneticAlgorithm
        optimizer = GA(populationSize=algorithmOptions.populationSize, crossoverRate=algorithmOptions.crossoverRate,
                        mutationRate=algorithmOptions.mutationRate, ɛ=algorithmOptions.ɛ, selection=get_option_func("selection", algorithmOptions.selection[1], algorithmOptions.selection[2]),
                        crossover=get_option_func("crossover", algorithmOptions.crossover), mutation=get_option_func("mutation", algorithmOptions.mutation),
                        metrics=[get_option_func("convergence", m[1], m[2]) for m in algorithmOptions.metrics])
        println("IN EVOLUTIONARYSCHEDULER INIT: ")
        println("OPTIMIZER IS: ", optimizer, " OF TYPE: ", typeof(optimizer))
        println("SELECTION IS: ", optimizer.selection, " OF TYPE: ", typeof(optimizer.selection))
        println("CROSSOVER IS: ", optimizer.crossover, " OF TYPE: ", typeof(optimizer.crossover))
        println("MUTATION IS: ", optimizer.mutation, " OF TYPE: ", typeof(optimizer.mutation))
        println("METRICS IS: ", optimizer.metrics, " OF TYPE: ", typeof(optimizer.metrics))
    elseif algorithmOptions isa DifferentialEvolution
        (; populationSize, F, n, selection, recombination, K, metrics) = algorithmOptions
        # TODO: Adjust to correct types for Evolutionary.jl
        optimizer = DE(populationSize, F, n, selection, recombination, K, metrics)
    elseif algorithmOptions isa EvolutionStrategy
        (; initStrategy, recombination, srecombination, mutation, smutation, μ, ρ, λ, selection, metrics) = algorithmOptions
        # TODO: Adjust to correct types for Evolutionary.jl
        optimizer = ES(initStrategy, recombination, srecombination, mutation, smutation, μ, ρ, λ, selection, metrics)
    elseif algorithmOptions isa ConvarianceMatrixAdaptionEvolutionStrategy
        (; μ, λ, c_1, c_c, c_μ, c_σ, σ₀, cₘ, wᵢ, metrics) = algorithmOptions
        # TODO: Adjust to correct types for Evolutionary.jl
        optimizer = CMAES
    elseif algorithmOptions isa GeneticProgramming
        (; populationSize, terminals, functions, mindepth, maxdepth, crossover, mutation, selection,
            crossoverRate, mutationRate, initialization, simplify, metrics) = algorithmOptions
        # TODO: Adjust to correct types for Evolutionary.jl
        optimizer = TreeGP(populationSize, terminals, functions, mindepth, maxdepth, crossover, mutation, selection,
        crossoverRate, mutationRate, initialization, simplify, metrics)
    elseif algorithmOptions isa NonDominatedSortingGeneticAlgorithm
        (; populationSize, crossoverRate, mutationRate, selection, crossover, mutation, metrics) = algorithmOptions
        # TODO: Adjust to correct types for Evolutionary.jl
        optimizer = NSGA2(populationSize, crossoverRate, mutationRate, selection, crossover, mutation, metrics)
    else
        error("Unknown Evolutionary algorithm type.")
    end
    return EvolutionaryScheduler(resolution, interval, optimizer)
end

"""
    schedule(ess, EvolutionaryScheduler, useCases, t)

Schedule the operation of `ess` with `EvolutionaryScheduler` given `useCases`
"""
function schedule(
    ess,
    scheduler::EvolutionaryScheduler,
    useCases::AbstractVector{<:UseCase},
    tStart::Dates.DateTime,
)
    idxEA = findfirst(uc -> uc isa EnergyArbitrage, useCases)
    idxReg = findfirst(uc -> uc isa Regulation, useCases)
    if idxEA !== nothing
        objective_func = get_objective_func(useCases[idxEA], scheduler, tStart)
    elseif idxReg !== nothing
        objective_func = get_objective_func(useCases[idxReg], scheduler, tStart)
    end
    result = Evolutionary.optimize(objective_func, zeros(Int(floor(scheduler.interval / scheduler.resolution))), scheduler.optimizer)
soc_vector = [0.0] # How do schedule and soc vectors really get filled in?
return Schedule(
    result.minimizer,
    tStart;
    resolution = scheduler.resolution,
    SOC = soc_vector,
)
end


function get_objective_func(::UseCase, ::EvolutionaryScheduler, ::Dates.DateTime)
    f(power_array) = 0
end

function get_objective_func(
    ucEA::EnergyArbitrage,
    scheduler::EvolutionaryScheduler,
    tStart::Dates.DateTime,
)
    function f(power_array)
        println("IN THE OBJECTIVE_FUNC, POWER ARRAY IS: ", typeof(power_array))
        println(power_array)
        println("FORECAST_PRICE IS: ", typeof(ucEA))
        println(forecast_price(ucEA))
        return FixedIntervalTimeSeries(tStart, scheduler.resolution, power_array) * forecast_price(ucEA)
    end
return f
end

function get_objective_func(
    ucReg::Regulation,
    scheduler::EvolutionaryScheduler,
    tStart::Dates.DateTime,
)
    function f(power_array)
        # regulation capacity and service performance
        regOp = FixedIntervalTimeSeries(
            tStart,
            scheduler.resolution,
            [RegulationOperationPoint(x, 0) for x in power_array],
        )
        regulation_income(regOp, ucReg)
    end
end
