
"""
    VariableIntervalTimeSeries

`VariableIntervalTimeSeries` represents a time series defined with variable time intervals.
The value of time series is defined as `value[i]` during the `i`th time period (from `t[i]` to `t[i + 1]`),
where `1 ≤ i ≤ length(value)` and `length(t) == length(value) + 1`.
"""
struct VariableIntervalTimeSeries{V,ST<:Series{V}} <: TimeSeries{V, ST}
    t::Vector{Dates.DateTime}
    value::ST
    VariableIntervalTimeSeries(t::AbstractVector{Dates.DateTime}, v::ST) where {V,ST<:Series{V}} =
        if length(t) == length(v) + 1
            new{V,ST}(t, v)
        else
            error(
                "Incompatible lengths: length(t) = $(length(t)), length(v) = $(length(v))",
            )
        end
end
VariableIntervalTimeSeries(t::AbstractVector{Dates.DateTime}, v::AbstractVector) =
    VariableIntervalTimeSeries(t, PeriodSeries(v))

Base.iterate(ts::VariableIntervalTimeSeries, index = 1) =
    index > length(ts) ? nothing :
    ((ts.value[index], ts.t[index], ts.t[index+1]), index + 1)
Base.length(ts::VariableIntervalTimeSeries) = length(ts.value)
Base.eltype(
    ::Type{VariableIntervalTimeSeries{V,ST}} where {ST<:PeriodSeries{V}},
) where {V} = Tuple{V,DateTime,DateTime}
Base.eltype(::Type{VariableIntervalTimeSeries{V,ST}} where {ST<:PointSeries{V}}) where {V} =
    Tuple{V,DateTime,DateTime}

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