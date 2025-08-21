# is_period(::PeriodTimeSeries) = true
# is_period(::PointTimeSeries) = false

struct FixedIntervalTimeSeries{R<:Dates.Period,V,ST<:Series{V}} <: TimeSeries{V,ST}
    tStart::Dates.DateTime
    resolution::R
    value::ST
end

"""
    FixedIntervalTimeSeries(tStart::DateTime, resolution::Period, v::AbstractVector)

Create a fixed interval time series of the period type by default when constructor with an AbstractVector `v`.
"""
FixedIntervalTimeSeries(
    tStart::Dates.DateTime,
    resolution::Dates.Period,
    v::AbstractVector,
) = FixedIntervalTimeSeries(tStart, resolution, PeriodSeries(v))

VariableIntervalTimeSeries(ts::FixedIntervalTimeSeries) =
    VariableIntervalTimeSeries(timestamps(ts), ts.value)

Base.iterate(ts::FixedIntervalTimeSeries, index = 1) =
    index > length(ts) ? nothing :
    (
        (
            ts.value[index],
            ts.tStart + ts.resolution * (index - 1),
            ts.tStart + ts.resolution * index,
        ),
        index + 1,
    )

Base.eltype(
    ::Type{
        FixedIntervalTimeSeries{<:Dates.Period,V,ST},
    } where {ST<:PeriodSeries{V}} where {V},
) = Tuple{V,DateTime,DateTime}
Base.eltype(
    ::Type{
        FixedIntervalTimeSeries{<:Dates.Period,V,ST},
    } where {ST<:PointSeries{V}} where {V},
) = Tuple{Tuple{V,V},DateTime,DateTime}

Base.length(ts::FixedIntervalTimeSeries) = length(ts.value)

start_time(ts::FixedIntervalTimeSeries) = ts.tStart

end_time(ts::FixedIntervalTimeSeries) = ts.tStart + ts.resolution * length(ts)

timestamps(ts::FixedIntervalTimeSeries) =
    range(ts.tStart; step = ts.resolution, length = length(ts) + 1)

function get_values(
    ts::FixedIntervalTimeSeries{R,V,ST},
    tStart::DateTime,
    tEnd::DateTime,
) where {R<:Dates.Period,V,ST<:Series{V}}
    t1 = max(tStart, start_time(ts))
    t2 = min(tEnd, end_time(ts))
    if t1 < end_time(ts) && t2 ≥ start_time(ts)
        # some overlap time period
        idx1 = div(t1 - ts.tStart, ts.resolution) + 1
        idx2 = ceil(Int, (t2 - ts.tStart) / ts.resolution)
        ts.value[idx1:idx2]
    else
        ST(V[])
    end
end

function extract(
    ts::FixedIntervalTimeSeries{<:Dates.Period,V,ST},
    tStart::DateTime,
    tEnd::DateTime;
    extendToGrid::Bool = false,
) where {ST<:Series{V}} where {V}
    t1 = max(tStart, start_time(ts))
    t2 = min(tEnd, end_time(ts))
    if t1 < end_time(ts) && t2 ≥ start_time(ts)
        # some overlap time period
        idx1, rem1 = divrem(t1 - start_time(ts), ts.resolution)
        idx2, rem2 = divrem(t2 - start_time(ts), ts.resolution)
        if Dates.value(rem1) === 0 && Dates.value(rem2) === 0 || extendToGrid
            # Both start and end are aligned with resolution
            FixedIntervalTimeSeries(
                ts.tStart + ts.resolution * idx1,
                ts.resolution,
                ts.value[(idx1+1):(Dates.value(rem2) === 0 ? idx2 : idx2 + 1)],
            )
        else
            VariableIntervalTimeSeries(
                vcat(
                    [t1, (ts.tStart .+ (ts.resolution .* ((idx1+1):idx2)))...],
                    Dates.value(rem2) > 0 ? [t2] : Dates.DateTime[],
                ),
                extract(
                    ts.value,
                    (t1 - start_time(ts)) / ts.resolution,
                    (t2 - start_time(ts)) / ts.resolution,
                ),
            )
        end
    else
        # Return empty time series of same value type
        FixedIntervalTimeSeries(tStart, ts.resolution, ST())
    end
end

# ==================== WIP ========================

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

integrate(ts::FixedIntervalTimeSeries{<:Dates.Period,V,<:PeriodSeries{V}} where {V}) =
    sum(ts.value.vec) * (ts.resolution / Hour(1))
integrate(ts::FixedIntervalTimeSeries{<:Dates.Period,V,<:PointSeries{V}} where {V}) =
    if length(ts) > 0
        (sum(ts.value.vec) - ts.value.vec[1] / 2 - ts.value.vec[end] / 2) *
        (ts.resolution / Hour(1))
    else
        0
    end

mean(ts::FixedIntervalTimeSeries{<:Dates.Period,V,<:PeriodSeries{V}} where {V}) =
    sum(ts.value.vec) / length(ts)

function is_aligned(ts1::FixedIntervalTimeSeries, ts2::FixedIntervalTimeSeries)
    resSmaller, resLarger =
        ts1.resolution ≤ ts2.resolution ? (ts1.resolution, ts2.resolution) :
        (ts2.resolution, ts1.resolution)

    return Dates.value(resLarger % resSmaller) === 0 &&
           Dates.value((ts1.tStart - ts2.tStart) % resSmaller) === 0
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
    v1[iStart1:iStart1+vLength1-1] = upsample(ts1.value, resMultiple1).vec

    v2 = zeros(eltype(ts2.value), vLength)
    resMultiple2 = ts2.resolution ÷ res
    iStart2 = (ts2.tStart - tStart) ÷ res + 1
    vLength2 = length(ts2) * resMultiple2
    v2[iStart2:iStart2+vLength2-1] = upsample(ts2.value, resMultiple2).vec

    v = op.(v1, v2)
    FixedIntervalTimeSeries(tStart, res, v)
end

binary_operation(ts::FixedIntervalTimeSeries, x::Number, op) =
    FixedIntervalTimeSeries(ts.tStart, ts.resolution, op.(ts.value, x))
binary_operation(x::Number, ts::FixedIntervalTimeSeries, op) =
    FixedIntervalTimeSeries(ts.tStart, ts.resolution, op.(x, ts.value))

Base.:^(ts::FixedIntervalTimeSeries, x::Number) =
    FixedIntervalTimeSeries(ts.tStart, ts.resolution, ts.value .^ x)
