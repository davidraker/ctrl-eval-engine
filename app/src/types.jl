using Dates
using LinearAlgebra

abstract type Series{V} end

Base.iterate(s::Series, index = 1) = index > length(s) ? nothing : (s[index], index + 1)

Base.getindex(s::Series, indices::AbstractVector{<:Real}) = [s[i] for i in indices]
Base.push!(s::Series{V}, v::V) where {V} = push!(s.vec, v)

# Common accessor functions for Series types
"""
    raw_vector(s::Series)

Get the raw values vector from a Series.
Useful for direct data access and I/O operations.
"""
raw_vector(s::Series) = s.vec

"""
    raw_vector(s::Series, ::Type{T}) where T

Get the raw values vector converted to type T.
"""
raw_vector(s::Series, ::Type{T}) where {T} = T.(raw_vector(s))

struct PeriodSeries{V} <: Series{V}
    vec::Vector{V}
end
PeriodSeries{V}() where {V} = PeriodSeries{V}(V[])
PeriodSeries(v::AbstractVector{V}) where {V} = PeriodSeries{V}(v)

Base.getindex(s::PeriodSeries{V}, i::Integer) where {V} = s.vec[i]
Base.getindex(s::PeriodSeries{V}, r::AbstractUnitRange{<:Integer}) where {V} =
    PeriodSeries(s.vec[r])
Base.getindex(s::PeriodSeries{V}, i::Real) where {V} =
    0 ≤ i < length(s) ? s.vec[floor(Int, i)+1] : zero(eltype(s.vec))
Base.lastindex(s::PeriodSeries) = lastindex(s.vec)

Base.length(s::PeriodSeries{V}) where {V} = length(s.vec)
Base.eltype(::Type{PeriodSeries{V}}) where {V} = V

Base.append!(s1::PeriodSeries{V}, s2::PeriodSeries{V}) where {V} = append!(s1.vec, s2.vec)

extract(s::PeriodSeries, i1::Real, i2::Real) = begin
    idx1 = div(i1, 1.0)
    idx2, rem2 = divrem(i2, 1.0)
    PeriodSeries(s[vcat([i1], (idx1+1):(idx2-1), rem2 > 0 ? [i2] : Float64[])])
end

upsample(s::PeriodSeries, n::Integer) = begin
    if n < 1
        error("Upsampling factor must be greater than or equal to 1")
    end
    PeriodSeries(repeat(s.vec; inner = n))
end

struct PointSeries{V} <: Series{V}
    vec::Vector{V}

    function PointSeries{V}(v::AbstractVector{V} = V[]) where {V}
        if length(v) ≥ 1
            new(v)
        else
            new(V[])
        end
    end
end
PointSeries(v::AbstractVector{V}) where {V} = PointSeries{V}(v)

Base.getindex(s::PointSeries, i::Integer) = (s.vec[i], s.vec[i+1])
Base.getindex(s::PointSeries, r::AbstractUnitRange{<:Integer}) =
    PointSeries(s.vec[r[1]:r[end]+1])
Base.getindex(s::PointSeries, i::Real) = begin
    idx, λ = fldmod(i, 1.0)
    if λ == 0.0
        s.vec[Int(idx)+1]
    elseif 0 ≤ idx < length(s)
        s.vec[Int(idx)+1] * (1 - λ) + s.vec[Int(idx)+2] * λ
    else
        zero(eltype(s.vec))
    end
end
Base.lastindex(s::PointSeries) = lastindex(s.vec) - 1

Base.length(s::PointSeries) = length(s.vec) ≥ 2 ? length(s.vec) - 1 : 0
Base.eltype(::Type{PointSeries{V}}) where {V} = Tuple{V,V}

Base.append!(s1::PointSeries{V}, s2::PointSeries{V}) where {V} = begin
    if s1.vec[end] != s2.vec[1]
        s1.vec[end] = (s1.vec[end] + s2.vec[1]) / 2
    end
    append!(s1.vec, s2.vec[2:end])
end

extract(s::PointSeries, i1::Real, i2::Real) = begin
    idx1 = div(i1, 1.0)
    idx2, rem2 = divrem(i2, 1.0)
    PointSeries(s[vcat([i1], (idx1+1):idx2, rem2 > 0 ? [i2] : Float64[])])
end

upsample(s::PointSeries, n::Integer) = begin
    if n < 1
        error("Upsampling factor must be greater than or equal to 1")
    end
    PointSeries(
        reduce(
            vcat,
            [[(seg[1] * (n - i) + seg[2] * i) / n for i = 1:n] for seg in s];
            init = [s.vec[1]],
        ),
    )
end

abstract type TimeSeries{V,ST<:Series{V}} end

"""
    get_index(ts::TimeSeries, index::Integer)

Return a tuple `(v, t1, t2)`,
where `t1` and `t2` are the beginning and the end, respectively,
of the time period defined by `index`,
and `v` is the value of `ts` in time period.

The type of `v` depends on the underlying series of `ts`.
"""
Base.getindex(ts::TimeSeries, i::Integer) = get_period(ts, i)

"""
    get_index(ts::TimeSeries, t::Dates.DateTime)

Return a tuple `(v, t1, t2)`,
where `t1` and `t2` are the beginning and the end, respectively,
of the time period enclosing `t`,
and `v` is the value of `ts` in time period.

The type of `v` depends on the underlying series of `ts`.
"""
Base.getindex(ts::TimeSeries, t::Dates.DateTime) = get_period(ts, t)

# Common accessor functions for TimeSeries types
"""
    raw_vector(ts::TimeSeries)

Get the raw values vector from a TimeSeries.
Useful for direct data access and I/O operations.
"""
raw_vector(ts::TimeSeries) = raw_vector(ts.value)

"""
    raw_vector(ts::TimeSeries, ::Type{T}) where T

Get the raw values vector converted to type T.
"""
raw_vector(ts::TimeSeries, ::Type{T}) where {T} = T.(raw_vector(ts))

"""
    duration(ts::TimeSeries)

Get the total duration of the time series.
"""
duration(ts::TimeSeries) = end_time(ts) - start_time(ts)

"""
    time_intervals(ts::TimeSeries)

Get the duration of each time interval in the series.
Requires the TimeSeries to have a timestamps method.
"""
time_intervals(ts::TimeSeries) = diff(timestamps(ts))

"""
    add_point!(ts::TimeSeries{V,ST}, timestamp::DateTime, value::V) where {V, ST <: Series{V}}

Add a new data point to the time series.
The value type must match the underlying series element type V.
This is a generic implementation that works for any TimeSeries subtype
that has a .t field for timestamps and a .value field with a .vec property.
"""
function add_point!(
    ts::TimeSeries{V,ST},
    timestamp::DateTime,
    value::V,
) where {V,ST<:Series{V}}
    if timestamp <= ts.t[end]
        error("New timestamp must be after the last timestamp")
    end
    push!(ts.value, value)
    push!(ts.t, timestamp)
    return ts
end

get_values(ts::TimeSeries) = ts.value

sample(ts::TimeSeries, tArray::AbstractArray{DateTime}) =
    map(t -> get_period(ts, t)[1], tArray)

function dot_multiply_time_series(ts1::TimeSeries, ts2::TimeSeries)
    tStart = max(start_time(ts1), start_time(ts2))
    tEnd = min(end_time(ts1), end_time(ts2))

    if tStart ≥ tEnd
        # The time ranges do not overlap
        return zero(eltype(ts1.value)) * zero(eltype(ts2.value))
    end

    integrate(binary_operation(ts1, ts2, *, tStart, tEnd))
end

"""
    integrate(ts::TimeSeries, tStart=start_time(ts), tEnd=end_time(ts))

Integrate `ts` from `tStart` to `tEnd` and return the result.
"""
integrate(ts::TimeSeries{V,ST}) where {V,ST<:PeriodSeries{V}} =
    sum(v * ((tEnd - tStart) / Hour(1)) for (v, tStart, tEnd) in ts)

integrate(ts::TimeSeries{V,ST}) where {V,ST<:PointSeries{V}} =
    sum((v[1] + v[2]) / 2 * ((tEnd - tStart) / Hour(1)) for (v, tStart, tEnd) in ts)

integrate(ts::TimeSeries, tStart::DateTime, tEnd::DateTime) =
    integrate(extract(ts, tStart, tEnd))

"""
    cum_integrate(ts::TimeSeries, tStart=start_time(ts), tEnd=end_time(ts))

Cumulatively integrate `ts` from `tStart` to `tEnd` and return the resultant `VariableIntervalTimeSeries`.
"""
cum_integrate(
    ts::TimeSeries{V,ST},
    tStart::DateTime,
    tEnd::DateTime,
) where {V,ST<:PeriodSeries{V}} = begin
    seg_integral = [v * ((t2 - t1) / Hour(1)) for (v, t1, t2) in extract(ts, tStart, tEnd)]

    VariableIntervalTimeSeries(timestamps(ts), cumsum(seg_integral))
end

cum_integrate(ts::TimeSeries) = cum_integrate(ts, start_time(ts), end_time(ts))

function binary_operation(ts1::TimeSeries, ts2::TimeSeries, op)
    tStart = min(start_time(ts1), start_time(ts2))
    tEnd = max(end_time(ts1), end_time(ts2))
    binary_operation(ts1, ts2, op, tStart, tEnd)
end

function binary_operation(
    ts1::TimeSeries{V1,ST1},
    ts2::TimeSeries{V2,ST2},
    op,
    tStart::DateTime,
    tEnd::DateTime,
) where {V1,V2,ST1<:PeriodSeries{V1},ST2<:PeriodSeries{V2}}
    t = [tStart]

    ts1Idx = get_index(ts1, tStart)
    v1, tPeriodEnd1 = if tStart < start_time(ts1)
        zero(V1), start_time(ts1)
    elseif tStart ≥ end_time(ts1)
        zero(V1), tEnd
    else
        get_period(ts1, ts1Idx)[[1, 3]]
    end

    ts2Idx = get_index(ts2, tStart)
    v2, tPeriodEnd2 = if tStart < start_time(ts2)
        zero(V2), start_time(ts2)
    elseif tStart ≥ end_time(ts2)
        zero(V2), tEnd
    else
        get_period(ts2, ts2Idx)[[1, 3]]
    end

    tPeriodEnd = min(tPeriodEnd1, tPeriodEnd2)
    push!(t, tPeriodEnd)

    v = op(v1, v2)
    value = [v]

    while tPeriodEnd < tEnd
        if tPeriodEnd1 == tPeriodEnd2
            # move both ts1 and ts2 forward by one time period
            ts1Idx += 1
            ts2Idx += 1
            v1, _, tPeriodEnd1 = get_period(ts1, ts1Idx)
            v2, _, tPeriodEnd2 = get_period(ts2, ts2Idx)
        elseif tPeriodEnd1 < tPeriodEnd2
            # this means tPeriodEnd == tPeriodEnd1, move ts1 forward by one time period
            ts1Idx += 1
            v1, _, tPeriodEnd1 = get_period(ts1, ts1Idx)
        else
            # this means tPeriodEnd == tPeriodEnd2, move ts2 forward by one time period
            ts2Idx += 1
            v2, _, tPeriodEnd2 = get_period(ts2, ts2Idx)
        end
        if isnothing(tPeriodEnd1)
            tPeriodEnd1 = tEnd
        end
        if isnothing(tPeriodEnd2)
            tPeriodEnd2 = tEnd
        end
        tPeriodEnd = min(tPeriodEnd1, tPeriodEnd2, tEnd)
        v = op(v1, v2)
        if value[end] == v
            t[end] = tPeriodEnd
        else
            push!(t, tPeriodEnd)
            push!(value, v)
        end
    end
    VariableIntervalTimeSeries(t, value)
end

Base.:+(ts1::TimeSeries, ts2::TimeSeries) = binary_operation(ts1, ts2, +)
Base.:+(ts::TimeSeries, x::Number) = binary_operation(ts, x, +)
Base.:+(x::Number, ts::TimeSeries) = binary_operation(x, ts, +)
Base.:-(ts1::TimeSeries, ts2::TimeSeries) = binary_operation(ts1, ts2, -)
Base.:-(ts::TimeSeries, x::Number) = binary_operation(ts, x, -)
Base.:-(x::Number, ts::TimeSeries) = binary_operation(x, ts, -)
Base.:*(ts1::TimeSeries, ts2::TimeSeries) = binary_operation(ts1, ts2, *)
Base.:*(ts::TimeSeries, x::Number) = binary_operation(ts, x, *)
Base.:*(x::Number, ts::TimeSeries) = binary_operation(x, ts, *)
Base.:/(ts1::TimeSeries, ts2::TimeSeries) = binary_operation(ts1, ts2, /)
Base.:/(ts::TimeSeries, x::Number) = binary_operation(ts, x, /)
Base.:^(ts::TimeSeries, x::Number) = binary_operation(ts, x, ^)

Base.:maximum(ts::TimeSeries) = maximum(ts.value)
Base.:minimum(ts::TimeSeries) = minimum(ts.value)

LinearAlgebra.dot(ts1::TimeSeries, ts2::TimeSeries) = dot_multiply_time_series(ts1, ts2)

"""
    mean(ts, t1=start_time(ts), t2=end_time(ts))

Calculate the average value of `ts` during the time period from `t1` to `t2`.
"""
mean(ts::TimeSeries) = integrate(ts) / ((end_time(ts) - start_time(ts)) / Hour(1))

mean(ts::TimeSeries, t1::DateTime, t2::DateTime) =
    integrate(ts, t1, t2) / ((t2 - t1) / Hour(1))

"""
    mean(ts::TimeSeries, t::AbstractVector{DateTime})

Return a new time series with the average values of `ts` during the time periods defined in `t`.
"""
function mean(ts::TimeSeries, t::AbstractVector{DateTime})
    values = [mean(ts, t[idx], t[idx+1]) for idx = 1:length(t)-1]
    VariableIntervalTimeSeries(t, values)
end

"""
    std(ts, t1=start_time(ts), t2=end_time(ts))

Calculate the standard deviation of `ts` during the time period from `t1` to `t2`.
"""
std(ts::TimeSeries, t1::DateTime, t2::DateTime) = std(extract(ts, t1, t2))

std(ts::TimeSeries{V,ST}) where {V,ST<:PeriodSeries{V}} = begin
    diff = ts - mean(ts)
    sqrt(mean(diff^2))
end

include("time-frame/VariableIntervalTimeSeries.jl")
include("time-frame/FixedIntervalTimeSeries.jl")
include("time-frame/RepeatedTimeSeries.jl")
include("time-frame/TimeFrame.jl")

struct SimSetting
    simStart::Dates.DateTime
    simEnd::Dates.DateTime
    temperature::Union{Real,TimeSeries}
end

get_temperature(setting::SimSetting, t::Dates.DateTime) =
    setting.temperature isa Real ? setting.temperature :
    get_period(setting.temperature, t)[1]

ScheduleHistory(
    t::AbstractVector{Dates.DateTime},
    p::AbstractVector{<:Real},
    soc::AbstractVector{<:Real},
    reg::AbstractVector{<:Real},
) = TimeFrame(
    t,
    [PeriodSeries(p), PointSeries(soc), PeriodSeries(reg)],
    [:powerKw, :SOC, :regCapKw],
)

# struct ScheduleHistory
#     t::AbstractVector{Dates.DateTime}
#     powerKw::AbstractVector{Float64}
#     SOC::AbstractVector{Float64}
#     regCapKw::AbstractVector{Float64}
# end

ScheduleHistory(t::AbstractVector{Dates.DateTime}, p::AbstractVector{<:Real}) =
    ScheduleHistory(t, p, zeros(length(p) + 1), zeros(length(p)))

"""
    OperationHistory

`OperationHistory` represents the operation history of an ESS over a period of time with corresponding timestamps `t`.
Both `length(t)` and `length(SOC)` should equal to `length(powerKw) + 1`.
"""
OperationHistory(
    t::AbstractVector{Dates.DateTime},
    p::AbstractVector{<:Real},
    soc::AbstractVector{<:Real},
    soh::AbstractVector{<:Real},
) = TimeFrame(
    t,
    [PeriodSeries(p), PointSeries(soc), PointSeries(soh)],
    [:powerKw, :SOC, :SOH],
)

# struct OperationHistory
#     data::TimeFrame

#     function OperationHistory(
#         t::AbstractVector{DateTime},
#         powerKw::AbstractVector{Float64},
#         SOC::AbstractVector{Float64},
#         SOH::AbstractVector{Float64},
#     )
#         if length(t) != length(SOC) || length(t) != length(SOH)
#             error("Length mismatch: t, SOC, and SOH must have the same length")
#         end
#         if length(powerKw) != length(t) - 1
#             error("Length mismatch: powerKw must have length equal to length(t) - 1")
#         end

#         data = TimeFrame(
#             t,
#             Dict(
#                 :powerKw => (PeriodType(), powerKw),
#                 :SOC => (PointType(), SOC),
#                 :SOH => (PointType(), SOH),
#             ),
#         )
#         new(data)
#     end
# end

# function Base.getproperty(op::OperationHistory, sym::Symbol)
#     if sym == :data
#         return getfield(op, :data)
#     elseif sym == :t
#         return op.data.timestamps
#     else
#         return op.data[sym]
#     end
# end

discharged_energy(op::TimeFrame) = begin
    pOP = op[:powerKw]
    dischargePeriods = pOP.value.vec .> 0
    durationHours = (pOP.t[2:end] .- pOP.t[1:end-1]) ./ Hour(1)
    sum(pOP.value.vec[dischargePeriods] .* durationHours[dischargePeriods])
end

charged_energy(op::TimeFrame) = begin
    pOP = op[:powerKw]
    chargePeriods = pOP.value.vec .< 0
    durationHours = (pOP.t[2:end] .- pOP.t[1:end-1]) ./ Hour(1)
    -sum(pOP.value.vec[chargePeriods] .* durationHours[chargePeriods])
end

mutable struct Progress
    progressPct::Float64
    schedule::TimeFrame
    operation::TimeFrame
end

mutable struct InvalidInput <: Exception
    msg::String
end

Base.print(io::IO, e::InvalidInput) = print(io, "Invalid input: ", e.msg)

struct InitializationFailure <: Exception
    msg::String
end

Base.print(io::IO, e::InitializationFailure) =
    print(io, "Failed to initialize a scheduler or real-time controller: ", e.msg)

abstract type BatteryInput end

struct LiIonBatteryInput <: BatteryInput
    powerCapacityKw::Float64
    energyCapacityKwh::Float64
    roundtripEfficiency::Float64
    cycleLife::Float64
end
