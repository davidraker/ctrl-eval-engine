using Dates
using LinearAlgebra

abstract type TimeSeries{V} end

include("time-frame/VariableIntervalTimeSeries.jl")
include("time-frame/FixedIntervalTimeSeries.jl")
include("time-frame/RepeatedTimeSeries.jl")
include("time-frame/TimeFrame.jl")

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

Cumulatively integrate `ts` from `tStart` to `tEnd` and return the resultant `VariableIntervalTimeSeries`.
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
