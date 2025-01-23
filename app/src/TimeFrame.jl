using Dates

abstract type TimeSeriesType end
struct PeriodType <: TimeSeriesType end
struct PointType <: TimeSeriesType end

struct TimeFrame
    timestamps::AbstractVector{Dates.DateTime}
    columns::Dict{Symbol, Tuple{TimeSeriesType, AbstractVector{Float64}}}
    
    function TimeFrame(timestamps::AbstractVector{Dates.DateTime}, 
                      columns::Dict{Symbol, Tuple{TimeSeriesType, Vector{Float64}}})
        for (key, (type, col)) in columns
            if type isa PeriodType
                if length(col) != length(timestamps) - 1
                    error("Incompatible lengths for period data. Expected $(length(timestamps) - 1), got $(length(col)).")
                end
            else
                if length(col) != length(timestamps)
                    error("Incompatible lengths for point data. Expected $(length(timestamps)), got $(length(col)).")
                end
            end
        end
        new(timestamps, columns)
    end
end

function Base.getindex(tf::TimeFrame, col::Symbol)
    _, data = tf.columns[col]
    return data
end

function Base.getproperty(tf::TimeFrame, sym::Symbol)
    if sym in (:timestamps, :columns)
        return getfield(tf, sym)
    else
        return getindex(tf, sym)
    end
end

function Base.propertynames(tf::TimeFrame)
    return tuple(:timestamps, :columns, keys(tf.columns)...)
end

columntype(tf::TimeFrame, col::Symbol) = tf.columns[col][1]

isperiod(tf::TimeFrame, col::Symbol) = columntype(tf, col) isa PeriodType

ispoint(tf::TimeFrame, col::Symbol) = columntype(tf, col) isa PointType
