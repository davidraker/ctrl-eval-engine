using Dates
using LinearAlgebra

include("TimeFrame.jl")

abstract type TimeSeries{V} end

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
integrate(ts::TimeSeries) = sum(v * ((tEnd - tStart) / Hour(1)) for (v, tStart, tEnd) in ts)

integrate(ts::TimeSeries, tStart::DateTime, tEnd::DateTime) =
    integrate(extract(ts, tStart, tEnd))

"""
    cum_integrate(ts::TimeSeries, tStart=start_time(ts), tEnd=end_time(ts))

Cummulatively integrate `ts` from `tStart` to `tEnd` and return the resultant `VariableIntervalTimeSeries`.
"""
cum_integrate(ts::TimeSeries, tStart::DateTime, tEnd::DateTime) = begin
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
    ts1::TimeSeries{V1},
    ts2::TimeSeries{V2},
    op,
    tStart::DateTime,
    tEnd::DateTime,
) where {V1,V2}
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

std(ts::TimeSeries) = begin
    diff = ts - mean(ts)
    sqrt(mean(diff^2))
end

############## VariableIntervalTimeSeries ########################
"""
    VariableIntervalTimeSeries

`VariableIntervalTimeSeries` represents a time series defined with variable time intervals.
The value of time series is defined as `value[i]` during the `i`th time period (from `t[i]` to `t[i + 1]`),
where `1 ≤ i ≤ length(value)` and `length(t) == length(value) + 1`.
"""
abstract type VariableIntervalTimeSeries{V} <: TimeSeries{V} end

struct VariableIntervalPeriodTimeSeries{V} <: VariableIntervalTimeSeries{V}
    t::Vector{Dates.DateTime}
    value::Vector{V}
    VariableIntervalPeriodTimeSeries(t, v::AbstractVector{V}) where {V} =
        length(t) == length(v) + 1 ? new{V}(t, v) : error("Incompatible lengths")
end

struct VariableIntervalPointTimeSeries{V} <: VariableIntervalTimeSeries{V}
    t::Vector{Dates.DateTime}
    value::Vector{V}
    VariableIntervalPointTimeSeries(t, v::AbstractVector{V}) where {V} =
        length(t) == length(v) ? new{V}(t, v) : error("Incompatible lengths")
end

Base.iterate(ts::VariableIntervalPeriodTimeSeries, index = 1) =
    index > length(ts) ? nothing :
    ((ts.value[index], ts.t[index], ts.t[index+1]), index + 1)
Base.eltype(::Type{VariableIntervalPeriodTimeSeries{V}}) where {V} =
    Tuple{V,DateTime,DateTime}
Base.length(ts::VariableIntervalPeriodTimeSeries) = length(ts.value)

Base.iterate(ts::VariableIntervalPointTimeSeries, index = 1) =
    index > length(ts) ? nothing :
    (((ts.value[index], ts.value[index+1]), ts.t[index], ts.t[index+1]), index + 1)
Base.eltype(::Type{VariableIntervalPointTimeSeries{V}}) where {V} =
    Tuple{V,DateTime,DateTime}
Base.length(ts::VariableIntervalPointTimeSeries) = length(ts.value) - 1

start_time(ts::VariableIntervalTimeSeries) = ts.t[1]

end_time(ts::VariableIntervalTimeSeries) = ts.t[end]

timestamps(ts::VariableIntervalTimeSeries) = ts.t

function get_values(ts::VariableIntervalTimeSeries, tStart::DateTime, tEnd::DateTime)
    t1 = max(tStart, start_time(ts))
    t2 = min(tEnd, end_time(ts))
    ts.value
    if t1 < ts.t[end] && t2 ≥ ts.t[1]
        # some overlap time period
        idx1 = findfirst(ts.t .> t1) - 1
        idx2 = findfirst(ts.t .≥ t2) - 1
        ts.value[idx1:idx2]
    else
        eltype(ts.value)[]
    end
end

function extract(ts::VariableIntervalTimeSeries, tStart::DateTime, tEnd::DateTime)
    t1 = max(tStart, start_time(ts))
    t2 = min(tEnd, end_time(ts))
    if t1 < ts.t[end] && t2 ≥ ts.t[1]
        # some overlap time period
        idx1 = findfirst(ts.t .> t1) - 1
        idx2 = findfirst(ts.t .≥ t2) - 1
        VariableIntervalTimeSeries([tStart, ts.t[idx1+1:idx2]..., t2], ts.value[idx1:idx2])
    else
        VariableIntervalTimeSeries([tStart], [])
    end
end

"""
    get_period(ts, index)

Return the value of `ts` at `t` and the `index`th defined time period.
"""
get_period(ts::VariableIntervalTimeSeries, index::Integer) = begin
    if index ≥ 1 && index ≤ length(ts)
        (ts.value[index], ts.t[index], ts.t[index+1])
    elseif index < 1
        (zero(eltype(ts.value)), nothing, ts.t[1])
    else
        (zero(eltype(ts.value)), ts.t[end], nothing)
    end
end

"""
    get_period(ts, t)

Return the value of `ts` at `t` and the defined time period that encloses `t`.
"""
get_period(ts::VariableIntervalTimeSeries, t::DateTime) = begin
    if t ≥ ts.t[1] && t < ts.t[end]
        index = findfirst(x -> x > t, ts.t) - 1
        (ts.value[index], ts.t[index], ts.t[index+1])
    elseif t < ts.t[1]
        (zero(eltype(ts.value)), nothing, ts.t[1])
    else
        (zero(eltype(ts.value)), ts.t[end], nothing)
    end
end

get_index(ts::VariableIntervalTimeSeries, t::DateTime) = begin
    if t ≥ ts.t[1] && t < ts.t[end]
        findfirst(x -> x > t, ts.t) - 1
    elseif t < ts.t[1]
        0
    else
        length(ts.value) + 1
    end
end

integrate(ts::VariableIntervalTimeSeries) = sum(ts.value .* (diff(ts.t) ./ Hour(1)))

binary_operation(ts::VariableIntervalTimeSeries, x::Number, op) =
    VariableIntervalTimeSeries(ts.t, op.(ts.value, x))
binary_operation(x::Number, ts::VariableIntervalTimeSeries, op) =
    VariableIntervalTimeSeries(ts.t, op.(x, ts.value))

Base.:^(ts::VariableIntervalTimeSeries, x::Number) =
    VariableIntervalTimeSeries(ts.t, ts.value .^ x)

mean(ts::VariableIntervalTimeSeries) =
    sum(diff(ts.t) ./ Hour(1) .* ts.value) / ((ts.t[end] - ts.t[1]) / Hour(1))

############## FixedIntervalTimeSeries ########################
abstract type FixedIntervalTimeSeries{R<:Dates.Period,V} <: TimeSeries{V} end

# abstract type PointTimeSeries <: TimeSeries end

# abstract type PeriodTimeSeries <: TimeSeries end

# is_period(::PeriodTimeSeries) = true
# is_period(::PointTimeSeries) = false

struct FixedIntervalPeriodTimeSeries{R<:Dates.Period,V} <: FixedIntervalTimeSeries{R,V}
    tStart::Dates.DateTime
    resolution::R
    value::Vector{V}
end

struct FixedIntervalPointTimeSeries{R<:Dates.Period,V} <: FixedIntervalTimeSeries{R,V}
    tStart::Dates.DateTime
    resolution::R
    value::Vector{V}
end

VariableIntervalTimeSeries(ts::FixedIntervalTimeSeries) =
    VariableIntervalTimeSeries(timestamps(ts), ts.value)

Base.iterate(ts::FixedIntervalPeriodTimeSeries, index = 1) =
    index > length(ts) ? nothing :
    (
        (
            ts.value[index],
            ts.tStart + ts.resolution * (index - 1),
            ts.tStart + ts.resolution * index,
        ),
        index + 1,
    )

Base.iterate(ts::FixedIntervalPointTimeSeries, index = 1) =
    index > length(ts) ? nothing :
    (
        (
            (ts.value[index], ts.value[index+1]),
            ts.tStart + ts.resolution * (index - 1),
            ts.tStart + ts.resolution * index,
        ),
        index + 1,
    )

Base.eltype(::Type{FixedIntervalPeriodTimeSeries{<:Dates.Period,V}}) where {V} =
    Tuple{V,DateTime,DateTime}
Base.eltype(::Type{FixedIntervalPointTimeSeries{<:Dates.Period,V}}) where {V} =
    Tuple{Tuple{V,V},DateTime,DateTime}

Base.length(ts::FixedIntervalPeriodTimeSeries) = length(ts.value)
Base.length(ts::FixedIntervalPointTimeSeries) = length(ts.value) - 1

start_time(ts::FixedIntervalTimeSeries) = ts.tStart

end_time(ts::FixedIntervalTimeSeries) = ts.tStart + ts.resolution * length(ts)

timestamps(ts::FixedIntervalTimeSeries) =
    range(ts.tStart; step = ts.resolution, length = length(ts) + 1)

# ==================== WIP ========================

function get_values(ts::FixedIntervalPeriodTimeSeries, tStart::DateTime, tEnd::DateTime)
    t1 = max(tStart, start_time(ts))
    t2 = min(tEnd, end_time(ts))
    if t1 < end_time(ts) && t2 ≥ start_time(ts)
        # some overlap time period
        idx1 = div(t1 - ts.tStart, ts.resolution) + 1
        idx2 = ceil(Int, (t2 - ts.tStart) / ts.resolution)
        ts.value[idx1:idx2]
    else
        eltype(ts.value)[]
    end
end

function get_values(ts::FixedIntervalPointTimeSeries, tStart::DateTime, tEnd::DateTime)
    t1 = max(tStart, start_time(ts))
    t2 = min(tEnd, end_time(ts))
    if t1 < end_time(ts) && t2 ≥ start_time(ts)
        # some overlap time period
        idx1 = div(t1 - ts.tStart, ts.resolution) + 1
        idx2 = ceil(Int, (t2 - ts.tStart) / ts.resolution)
        ts.value[idx1:idx2+1]
    else
        eltype(ts.value)[]
    end
end

function extract(ts::FixedIntervalTimeSeries, tStart::DateTime, tEnd::DateTime)
    t1 = max(tStart, start_time(ts))
    t2 = min(tEnd, end_time(ts))
    if t1 < end_time(ts) && t2 ≥ start_time(ts)
        # some overlap time period
        idx1, rem1 = divrem(t1 - start_time(ts), ts.resolution)
        idx2, rem2 = divrem(t2 - start_time(ts), ts.resolution)
        if Dates.value(rem1) === 0 && Dates.value(rem2) === 0
            # Both start and end are aligned with resolution
            typeof(ts)(
                ts.tStart + ts.resolution * idx1,
                ts.resolution,
                get_values(ts, tStart, tEnd),
            )
        else
            if ts isa FixedIntervalPeriodTimeSeries
                VariableIntervalPeriodTimeSeries(
                    [t1, (ts.tStart .+ (ts.resolution .* ((idx1+1):idx2)))..., t2],
                    get_values(ts, tStart, tEnd),
                )
            else
                λ1 = rem1 / ts.resolution
                λ2 = rem2 / ts.resolution
                VariableIntervalPointTimeSeries(
                    vcat(
                        [t1, (ts.tStart .+ (ts.resolution .* ((idx1+1):idx2)))...],
                        λ2 > 0 ? [t2] : [],
                    ),
                    vcat(
                        [
                            ts.value[idx1+1] * (1 - λ1) + ts.value[idx1+2] * λ1,
                            ts.value[(idx1+2):(idx2+1)]...,
                        ],
                        λ2 > 0 ? [ts.value[idx2+1] * (1 - λ2) + ts.value[idx2+2] * λ2] : [],
                    ),
                )
            end
        end
    else
        FixedIntervalPeriodTimeSeries(tStart, ts.resolution, Float64[])
    end
end

get_period(ts::FixedIntervalTimeSeries, index::Integer) = begin
    if index ≥ 1 && index ≤ length(ts)
        (
            ts.value[index],
            ts.tStart + ts.resolution * (index - 1),
            ts.tStart + ts.resolution * index,
        )
    elseif index < 1
        (zero(eltype(ts.value)), nothing, start_time(ts))
    else
        (zero(eltype(ts.value)), end_time(ts), nothing)
    end
end

get_period(ts::FixedIntervalTimeSeries, t::DateTime) = begin
    index = floor(Int64, /(promote(t - ts.tStart, ts.resolution)...)) + 1
    get_period(ts, index)
end

get_index(ts::FixedIntervalTimeSeries, t::DateTime) = begin
    index = fld(t - ts.tStart, ts.resolution) + 1
    if index ≥ 1 && index ≤ length(ts)
        index
    elseif index < 1
        0
    else
        length(ts) + 1
    end
end

integrate(ts::FixedIntervalTimeSeries) = sum(ts.value) * (ts.resolution / Hour(1))

function is_aligned(ts1::FixedIntervalTimeSeries, ts2::FixedIntervalTimeSeries)
    resSmaller, resLarger =
        ts1.resolution ≤ ts2.resolution ? (ts1.resolution, ts2.resolution) :
        (ts2.resolution, ts1.resolution)

    if Dates.value(resLarger % resSmaller) === 0 &&
       Dates.value((ts1.tStart - ts2.tStart) % resSmaller) === 0
        true
    else
        false
    end
end

function binary_operation(ts1::FixedIntervalTimeSeries, ts2::FixedIntervalTimeSeries, op)
    if !is_aligned(ts1, ts2)
        return binary_operation(VariableIntervalTimeSeries(ts1), ts2, op)
    end
    res = ts1.resolution ≤ ts2.resolution ? ts1.resolution : ts2.resolution
    tStart = ts1.tStart ≤ ts2.tStart ? ts1.tStart : ts2.tStart
    tEnd = end_time(ts1) ≤ end_time(ts2) ? end_time(ts2) : end_time(ts1)
    vLength = (tEnd - tStart) ÷ res

    v1 = zeros(eltype(ts1.value), vLength)
    resMultiple1 = ts1.resolution ÷ res
    iStart1 = (ts1.tStart - tStart) ÷ res + 1
    vLength1 = length(ts1) * resMultiple1
    v1[iStart1:iStart1+vLength1-1] = repeat(ts1.value; inner = resMultiple1)

    v2 = zeros(eltype(ts2.value), vLength)
    resMultiple2 = ts2.resolution ÷ res
    iStart2 = (ts2.tStart - tStart) ÷ res + 1
    vLength2 = length(ts2) * resMultiple2
    v2[iStart2:iStart2+vLength2-1] = repeat(ts2.value; inner = resMultiple2)

    v = op.(v1, v2)
    FixedIntervalTimeSeries(tStart, res, v)
end

binary_operation(ts::FixedIntervalTimeSeries, x::Number, op) =
    FixedIntervalTimeSeries(ts.tStart, ts.resolution, op.(ts.value, x))
binary_operation(x::Number, ts::FixedIntervalTimeSeries, op) =
    FixedIntervalTimeSeries(ts.tStart, ts.resolution, op.(x, ts.value))

Base.:^(ts::FixedIntervalTimeSeries, x::Number) =
    FixedIntervalTimeSeries(ts.tStart, ts.resolution, ts.value .^ x)

mean(ts::FixedIntervalTimeSeries) = sum(ts.value) / length(ts)

############## RepeatedTimeSeries ########################
struct RepeatedTimeSeries{V} <: TimeSeries{V}
    core::Union{FixedIntervalTimeSeries{<:Dates.Period,V},VariableIntervalTimeSeries{V}}
    iStart::Int
    startOffset::Dates.Period
    iEnd::Int
    endOffset::Dates.Period
    RepeatedTimeSeries(
        core::Union{
            FixedIntervalTimeSeries{<:Dates.Period,V},
            VariableIntervalTimeSeries{V},
        },
        iStart::Integer,
        startOffset::Dates.Period,
        iEnd::Integer,
        endOffset::Dates.Period,
    ) where {V} =
        if startOffset ≥ Dates.Second(0) && endOffset ≤ Dates.Second(0)
            _, firstCorePeriodStart, firstCorePeriodEnd =
                get_period(core, mod1(iStart, length(core)))
            _, lastCorePeriodStart, lastCorePeriodEnd =
                get_period(core, mod1(iEnd, length(core)))
            if firstCorePeriodStart + startOffset < firstCorePeriodEnd &&
               lastCorePeriodEnd + endOffset ≥ lastCorePeriodStart
                new{V}(core, iStart, startOffset, iEnd, endOffset)
            else
                error("Start and end offsets must fall within the corresponding period")
            end
        else
            error("`startOffset` must be non-negative and `endOffset` must be non-positive")
        end
end

RepeatedTimeSeries(
    core::Union{FixedIntervalTimeSeries,VariableIntervalTimeSeries},
    iStart::Integer = 1,
    iEnd::Integer = length(core),
) = RepeatedTimeSeries(core, iStart, Second(0), iEnd, Second(0))

function RepeatedTimeSeries(
    core::Union{FixedIntervalTimeSeries,VariableIntervalTimeSeries},
    tStart::Dates.DateTime,
    tEnd::Dates.DateTime,
)
    coreDuration = end_time(core) - start_time(core)
    nRepStart, coreOffsetStart = fldmod(tStart - start_time(core), coreDuration)
    nRepEnd = cld(tEnd - start_time(core), coreDuration) - 1
    coreOffsetEnd = tEnd - start_time(core) - nRepEnd * coreDuration

    # Get the corresponding period in ts.core and offset
    coreIdxStart = get_index(core, start_time(core) + coreOffsetStart)
    iStart = nRepStart * length(core) + coreIdxStart
    offsetStart = tStart - (get_period(core, coreIdxStart)[2] + nRepStart * coreDuration)

    (coreIdxEnd, offsetEnd) = if coreOffsetEnd == coreDuration
        (length(core), Second(0))
    else
        idx = get_index(core, start_time(core) + coreOffsetEnd)
        corePeriodEnd = get_period(core, idx)[3]
        if corePeriodEnd == start_time(core) + coreOffsetEnd
            (idx - 1, Second(0))
        else
            (idx, tEnd - (corePeriodEnd + nRepEnd * coreDuration))
        end
    end
    iEnd = nRepEnd * length(core) + coreIdxEnd

    RepeatedTimeSeries(core, iStart, offsetStart, iEnd, offsetEnd)
end

start_time(ts::RepeatedTimeSeries) = get_period(ts, ts.iStart)[2]
end_time(ts::RepeatedTimeSeries) = get_period(ts, ts.iEnd)[3]

get_period(ts::RepeatedTimeSeries, index::Integer) = begin
    if ts.iStart > ts.iEnd
        return (zero(eltype(ts.core.value)), nothing, nothing)
    end

    if index < ts.iStart
        return (zero(eltype(ts.core.value)), nothing, start_time(ts))
    elseif index > ts.iEnd
        return (zero(eltype(ts.core.value)), end_time(ts), nothing)
    end

    nRep = cld(index, length(ts.core)) - 1
    coreDuration = end_time(ts.core) - start_time(ts.core)
    v, t1, t2 = get_period(ts.core, mod1(index, length(ts.core)))

    if index == ts.iStart
        return (v, t1 + nRep * coreDuration + ts.startOffset, t2 + nRep * coreDuration)
    end

    if index == ts.iEnd
        return (v, t1 + nRep * coreDuration, t2 + nRep * coreDuration + ts.endOffset)
    end

    return (v, t1 + nRep * coreDuration, t2 + nRep * coreDuration)
end

get_index(ts::RepeatedTimeSeries, t::DateTime) = begin
    if t ≥ start_time(ts) && t < end_time(ts)
        # Calculate the offset within ts.core
        nRep, offset =
            fldmod(t - start_time(ts.core), end_time(ts.core) - start_time(ts.core))

        # Get the corresponding period in ts.core
        nRep * length(ts.core) + get_index(ts.core, start_time(ts.core) + offset)
    elseif t < start_time(ts)
        ts.iStart - 1
    else
        ts.iEnd + 1
    end
end

get_period(ts::RepeatedTimeSeries, t::DateTime) = get_period(ts, get_index(ts, t))

Base.iterate(ts::RepeatedTimeSeries, index::Integer = ts.iStart) =
    index > ts.iEnd ? nothing : (get_period(ts, index), index + 1)

Base.eltype(::Type{RepeatedTimeSeries{V}}) where {V} = Tuple{V,DateTime,DateTime}
Base.length(ts::RepeatedTimeSeries) = ts.iEnd - ts.iStart + 1

function timestamps(ts::RepeatedTimeSeries)
    push!(
        [get_period(ts, index)[2] for index = ts.iStart:ts.iEnd],
        get_period(ts, ts.iEnd)[3],
    )
end

get_values(ts::RepeatedTimeSeries) =
    [ts.core.value[mod1(index, length(ts.core))] for index = ts.iStart:ts.iEnd]

function extract(ts::RepeatedTimeSeries, tStart::DateTime, tEnd::DateTime)
    t1 = max(tStart, start_time(ts))
    t2 = min(tEnd, end_time(ts))

    iRep1, offsetTime1 =
        fldmod(t1 - start_time(ts.core), end_time(ts.core) - start_time(ts.core))
    offsetIndex1 = get_index(ts.core, start_time(ts.core) + offsetTime1)
    idx1 = iRep1 * length(ts.core) + offsetIndex1

    iRep2 = cld(t2 - start_time(ts.core), end_time(ts.core) - start_time(ts.core)) - 1
    offsetTime2 =
        t2 - (start_time(ts.core) + iRep2 * (end_time(ts.core) - start_time(ts.core)))
    offsetIndex2 = get_index(ts.core, start_time(ts.core) + offsetTime2)
    if offsetIndex2 === nothing
        offsetIndex2 = length(ts.core)
    elseif start_time(ts.core) + offsetTime2 == get_period(ts.core, offsetIndex2)[2]
        offsetIndex2 -= 1
    end
    idx2 = iRep2 * length(ts.core) + offsetIndex2

    RepeatedTimeSeries(
        ts.core,
        idx1,
        start_time(ts.core) + offsetTime1 - get_period(ts.core, offsetIndex1)[2],
        idx2,
        start_time(ts.core) + offsetTime2 - get_period(ts.core, offsetIndex2)[3],
    )
end

get_values(ts::RepeatedTimeSeries, tStart::DateTime, tEnd::DateTime) =
    get_values(extract(ts, tStart, tEnd))

binary_operation(ts::RepeatedTimeSeries, x::Number, op) =
    RepeatedTimeSeries(op(ts.core, x), ts.iStart, ts.startOffset, ts.iEnd, ts.endOffset)

binary_operation(x::Number, ts::RepeatedTimeSeries, op) =
    RepeatedTimeSeries(op(x, ts.core), ts.iStart, ts.startOffset, ts.iEnd, ts.endOffset)

Base.:minimum(ts::RepeatedTimeSeries) = minimum(get_values(ts))
Base.:maximum(ts::RepeatedTimeSeries) = maximum(get_values(ts))

struct SimSetting
    simStart::Dates.DateTime
    simEnd::Dates.DateTime
    temperature::Union{Real,TimeSeries}
end

get_temperature(setting::SimSetting, t::Dates.DateTime) =
    setting.temperature isa Real ? setting.temperature :
    get_period(setting.temperature, t)[1]

struct ScheduleHistory
    t::AbstractVector{Dates.DateTime}
    powerKw::AbstractVector{Float64}
    SOC::AbstractVector{Float64}
    regCapKw::AbstractVector{Float64}
end

ScheduleHistory(t::AbstractVector{Dates.DateTime}, p::AbstractVector{Float64}) =
    ScheduleHistory(t, p, zeros(length(p) + 1), zeros(length(p)))

power(sh::ScheduleHistory) = VariableIntervalTimeSeries(sh.t, sh.powerKw)

"""
    OperationHistory

`OperationHistory` represents the operation history of an ESS over a period of time with corresponding timestamps `t`.
Both `length(t)` and `length(SOC)` should equal to `length(powerKw) + 1`.
"""
struct OperationHistory
    data::TimeFrame

    function OperationHistory(
        t::AbstractVector{DateTime},
        powerKw::AbstractVector{Float64},
        SOC::AbstractVector{Float64},
        SOH::AbstractVector{Float64},
    )
        if length(t) != length(SOC) || length(t) != length(SOH)
            error("Length mismatch: t, SOC, and SOH must have the same length")
        end
        if length(powerKw) != length(t) - 1
            error("Length mismatch: powerKw must have length equal to length(t) - 1")
        end

        data = TimeFrame(
            t,
            Dict(
                :powerKw => (PeriodType(), powerKw),
                :SOC => (PointType(), SOC),
                :SOH => (PointType(), SOH),
            ),
        )
        new(data)
    end
end

function Base.getproperty(op::OperationHistory, sym::Symbol)
    if sym == :data
        return getfield(op, :data)
    elseif sym == :t
        return op.data.timestamps
    else
        return op.data[sym]
    end
end

start_time(op::OperationHistory) = op.t[1]
end_time(op::OperationHistory) = op.t[end]
power(op::OperationHistory) = VariableIntervalTimeSeries(op.t, op.powerKw)

discharged_energy(op::OperationHistory) = begin
    dischargePeriods = op.powerKw .> 0
    durationHours = (op.t[2:end] .- op.t[1:end-1]) ./ Hour(1)
    sum(op.powerKw[dischargePeriods] .* durationHours[dischargePeriods])
end

charged_energy(op::OperationHistory) = begin
    chargePeriods = op.powerKw .< 0
    durationHours = (op.t[2:end] .- op.t[1:end-1]) ./ Hour(1)
    -sum(op.powerKw[chargePeriods] .* durationHours[chargePeriods])
end

Base.iterate(op::OperationHistory, index = 1) =
    index > length(op.powerKw) || index + 1 > length(op.t) ? nothing :
    ((op.t[index], op.t[index+1], op.powerKw[index]), index + 1)

Base.eltype(::Type{OperationHistory}) = Tuple{DateTime,DateTime,Float64}
Base.length(op::OperationHistory) = length(op.powerKw)

mutable struct Progress
    progressPct::Float64
    schedule::ScheduleHistory
    operation::OperationHistory
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
