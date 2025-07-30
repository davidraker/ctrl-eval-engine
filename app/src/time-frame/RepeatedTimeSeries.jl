
struct RepeatedTimeSeries{V, ST <: Series{V}} <: TimeSeries{V, ST}
    core::Union{FixedIntervalTimeSeries{<:Dates.Period,V,ST},VariableIntervalTimeSeries{V,ST}}
    iStart::Int
    startOffset::Dates.Period
    iEnd::Int
    endOffset::Dates.Period
    RepeatedTimeSeries(
        core::Union{
            FixedIntervalTimeSeries{<:Dates.Period,V,ST},
            VariableIntervalTimeSeries{V,ST},
        },
        iStart::Integer,
        startOffset::Dates.Period,
        iEnd::Integer,
        endOffset::Dates.Period,
    ) where {V, ST <: Series{V}} =
        if startOffset ≥ Dates.Second(0) && endOffset ≤ Dates.Second(0)
            _, firstCorePeriodStart, firstCorePeriodEnd =
                get_period(core, mod1(iStart, length(core)))
            _, lastCorePeriodStart, lastCorePeriodEnd =
                get_period(core, mod1(iEnd, length(core)))
            if firstCorePeriodStart + startOffset < firstCorePeriodEnd &&
               lastCorePeriodEnd + endOffset ≥ lastCorePeriodStart
                new{V,ST}(core, iStart, startOffset, iEnd, endOffset)
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