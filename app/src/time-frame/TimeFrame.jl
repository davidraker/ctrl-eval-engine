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

"""
    add_column!(tf::TimeFrame, header::Symbol, column::Series)

Add a new column to an existing TimeFrame by modifying it in place.
The column must have the correct length (length(timestamps) - 1).

# Arguments
- `tf::TimeFrame`: The TimeFrame to modify
- `header::Symbol`: The name/header for the new column
- `column::Series`: The data for the new column

# Example
```julia
add_column!(tf, :newColumn, PeriodSeries([1.0, 2.0, 3.0]))
```
"""
function add_column!(tf::TimeFrame, header::Symbol, column::Series)
    # Check if header already exists
    if header in tf.headers
        error("Column '$header' already exists in TimeFrame")
    end
    
    # Check column length compatibility
    expected_length = length(tf.t) - 1
    if length(column) != expected_length
        error("Incompatible column length. Expected $expected_length, got $(length(column))")
    end
    
    # Add to existing vectors
    push!(tf.headers, header)
    push!(tf.columns, column)
    
    return tf
end

"""
    add_column!(tf::TimeFrame, header::Symbol, data::AbstractVector)

Add a new column to an existing TimeFrame using a vector of data.
The data will be wrapped in a PeriodSeries automatically.

# Example
```julia
add_column!(tf, :newColumn, [1.0, 2.0, 3.0])
```
"""
function add_column!(tf::TimeFrame, header::Symbol, data::AbstractVector)
    return add_column!(tf, header, PeriodSeries(data))
end

"""
    add_column(tf::TimeFrame, header::Symbol, column::Series)

Add a new column to an existing TimeFrame. Returns a new TimeFrame instance
with the additional column. The column must have the correct length 
(length(timestamps) - 1).

# Arguments
- `tf::TimeFrame`: The existing TimeFrame
- `header::Symbol`: The name/header for the new column
- `column::Series`: The data for the new column

# Example
```julia
new_tf = add_column(tf, :newColumn, PeriodSeries([1.0, 2.0, 3.0]))
```
"""
function add_column(tf::TimeFrame, header::Symbol, column::Series)
    # Check if header already exists
    if header in tf.headers
        error("Column '$header' already exists in TimeFrame")
    end
    
    # Check column length compatibility
    expected_length = length(tf.t) - 1
    if length(column) != expected_length
        error("Incompatible column length. Expected $expected_length, got $(length(column))")
    end
    
    # Create new TimeFrame with the additional column
    new_headers = [tf.headers..., header]
    new_columns = [tf.columns..., column]
    
    return TimeFrame(tf.t, new_columns, new_headers)
end

"""
    add_column(tf::TimeFrame, header::Symbol, data::AbstractVector)

Add a new column to an existing TimeFrame using a vector of data.
The data will be wrapped in a PeriodSeries automatically.

# Example
```julia
new_tf = add_column(tf, :newColumn, [1.0, 2.0, 3.0])
```
"""
function add_column(tf::TimeFrame, header::Symbol, data::AbstractVector)
    return add_column(tf, header, PeriodSeries(data))
end

power(tf::TimeFrame) = tf[:powerKw]

timestamps(tf::TimeFrame) = tf.t

start_time(op::TimeFrame) = timestamps(op)[1]
end_time(op::TimeFrame) = timestamps(op)[end]

# Convenience accessors for common TimeFrame operations
"""
    column_names(tf::TimeFrame)

Get the column names (headers) of a TimeFrame.
"""
column_names(tf::TimeFrame) = tf.headers

"""
    column_data(tf::TimeFrame, col::Symbol)

Get the raw data vector for a specific column, bypassing the TimeSeries wrapper.
Useful for direct data access and I/O operations.
"""
column_data(tf::TimeFrame, col::Symbol) = raw_vector(tf[col])

"""
    column_data(tf::TimeFrame, col::Symbol, ::Type{T}) where T

Get the raw data vector for a specific column, converted to type T.
"""
column_data(tf::TimeFrame, col::Symbol, ::Type{T}) where T = raw_vector(tf[col], T)

"""
    add_data_point!(tf::TimeFrame, timestamp::DateTime, data::Dict{Symbol, <:Any})

Add a new data point to all columns of a TimeFrame simultaneously.
The data dictionary should contain values for all columns.

# Example
```julia
add_data_point!(tf, DateTime(2023, 1, 1, 12, 0), Dict(:powerKw => 100.0, :SOC => 0.8))
```
"""
function add_data_point!(tf::TimeFrame, timestamp::DateTime, data::Dict{Symbol, <:Any})
    # Verify all columns are present
    missing_cols = setdiff(tf.headers, keys(data))
    if !isempty(missing_cols)
        error("Missing data for columns: $missing_cols")
    end
    
    # Add data for each column
    for header in tf.headers
        push!(raw_vector(tf[header]), data[header])
    end
    
    # Add timestamp
    push!(tf.t, timestamp)
    
    return tf
end
