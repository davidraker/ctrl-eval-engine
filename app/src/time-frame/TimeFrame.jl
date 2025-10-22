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

Base.getindex(tf::TimeFrame, index::Integer, col::Symbol) = tf[col][index]

"""
    add_column!(tf::TimeFrame, header::Symbol, column::Series)

Add a new column to an existing TimeFrame by modifying it in place.
The column must have the correct length `length(timestamps) - 1`.

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
    expectedLength = length(tf.t) - 1
    if length(column) != expectedLength
        error("Incompatible column length. Expected $expectedLength, got $(length(column))")
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
    expectedLength = length(tf.t) - 1
    if length(column) != expectedLength
        error("Incompatible column length. Expected $expectedLength, got $(length(column))")
    end

    # Create new TimeFrame with the additional column
    newHeaders = [tf.headers..., header]
    newColumns = [tf.columns..., column]

    return TimeFrame(tf.t, newColumns, newHeaders)
end

timestamps(tf::TimeFrame) = tf.t

start_time(tf::TimeFrame) = timestamps(tf)[1]
end_time(tf::TimeFrame) = timestamps(tf)[end]

# General type to represent a single row/period in a TimeFrame
struct TimeFrameRow
    tfRef::TimeFrame
    iRow::Int
end

duration(tfr::TimeFrameRow) = tfr.tfRef.t[tfr.iRow+1] - tfr.tfRef.t[tfr.iRow]
start_time(tfr::TimeFrameRow) = tfr.tfRef.t[tfr.iRow]
end_time(tfr::TimeFrameRow) = tfr.tfRef.t[tfr.iRow+1]

Base.getindex(tfr::TimeFrameRow, col::Symbol) = tfr.tfRef[col][tfr.iRow]

Base.haskey(tfr::TimeFrameRow, col::Symbol) = col ∈ tfr.tfRef.headers

# Iterator for TimeFrame to produce TimeFrameRow objects
function Base.iterate(tf::TimeFrame, index = 1)
    if index > length(timestamps(tf)) - 1
        return nothing
    end

    return (TimeFrameRow(tf, index), index + 1)
end

Base.eltype(::Type{TimeFrame}) = TimeFrameRow
Base.length(tf::TimeFrame) = length(timestamps(tf)) - 1

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
column_data(tf::TimeFrame, col::Symbol, ::Type{T}) where {T} = raw_vector(tf[col], T)

"""
    Base.push!(tf::TimeFrame, timestamp::DateTime, data::NamedTuple)

Add a new data point to all columns of a TimeFrame simultaneously.
The data NamedTuple should contain values for all columns.

# Example

```julia
push!(tf, DateTime(2023, 1, 1, 12, 0), (powerKw = 100.0, SOC = 0.8))
```
"""
function Base.push!(tf::TimeFrame, timestamp::DateTime, data::NamedTuple)
    # Verify all columns are present
    dataKeys = Set(keys(data))
    headerKeys = Set(tf.headers)
    missingCols = setdiff(headerKeys, dataKeys)
    if !isempty(missingCols)
        error("Missing data for columns: $missingCols")
    end

    # Add data for each column
    for header in tf.headers
        push!(raw_vector(tf[header]), getproperty(data, header))
    end

    # Add timestamp
    push!(tf.t, timestamp)

    return tf
end

"""
    Base.push!(tf::TimeFrame, tfr::TimeFrameRow)

Append a TimeFrameRow to a TimeFrame. This adds the row's data and its end time as a new timestamp.

# Example

```julia
push!(tf, timeFrameRow)
```
"""
function Base.push!(tf::TimeFrame, tfr::TimeFrameRow)
    # Create NamedTuple from TimeFrameRow data
    data = NamedTuple{Tuple(tf.headers)}(Tuple(tfr[header] for header in tf.headers))
    return push!(tf, end_time(tfr), data)
end

"""
    Base.append!(tf1::TimeFrame, tf2::TimeFrame)

Append all rows from tf2 to tf1. Both TimeFrames must have the same column headers.

# Example

```julia
append!(tf1, tf2)
```
"""
function Base.append!(tf1::TimeFrame, tf2::TimeFrame)
    @assert tf1.t[end] == tf2.t[1] "TimeFrames must be contiguous"

    # Check that tf1.headers is a subset of tf2.headers
    if !(Set(tf1.headers) ⊆ Set(tf2.headers))
        error(
            "tf1 headers must be a subset of tf2 headers. tf1 headers: $(tf1.headers), tf2 headers: $(tf2.headers)",
        )
    end

    # Append all data
    for (iCol, header) in enumerate(tf1.headers)
        append!(tf1.columns[iCol], tf2.columns[findfirst(tf2.headers .== header)])
    end

    # Append timestamps (skip the first timestamp of tf2 to avoid duplication)
    append!(tf1.t, tf2.t[2:end])

    return tf1
end
