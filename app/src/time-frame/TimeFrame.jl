using Dates

abstract type TimeSeriesType end
struct PeriodType <: TimeSeriesType end
struct PointType <: TimeSeriesType end

struct TimeFrame
    t::Vector{Dates.DateTime}
    columns::Vector{<:Series}
    headers::Vector{Symbol}

    function TimeFrame(
        timestamps::AbstractVector{Dates.DateTime},
        columns::Vector{<:Series},
        headers::Vector{Symbol},
    )
        @assert length(headers) == length(columns) "Number of headers must match number of columns"
        incompatibleCols = length.(columns) .!= length(timestamps) - 1
        if any(incompatibleCols)
            error(
                "Incompatible lengths for columns: $(headers[incompatibleCols]). 
                Expected length $(length(timestamps) - 1), got lengths $(length.(columns[incompatibleCols]))",
            )
        end
        new(timestamps, columns, headers)
    end
end

function Base.getindex(tf::TimeFrame, col::Symbol)
    idx = findfirst(tf.headers .== col)
    @assert idx !== nothing "Column $col not found in TimeFrame"
    return VariableIntervalTimeSeries(tf.t, tf.columns[idx])
end

power(tf::TimeFrame) = tf[:powerKw]

timestamps(tf::TimeFrame) = tf.t

start_time(op::TimeFrame) = start_time(timestamps(op))
end_time(op::TimeFrame) = end_time(timestamps(op))
