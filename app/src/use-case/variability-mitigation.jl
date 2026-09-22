
struct VariabilityMitigation <: UseCase
    pvGenProfile::FixedIntervalTimeSeries{<:TimePeriod,Float64,PeriodSeries{Float64}}
    ratedPowerKw::Float64
end

"""
    VariabilityMitigation(input)

Construct an `VariabilityMitigation` object from `input` dictionary or array
"""
VariabilityMitigation(config::AbstractDict) = VariabilityMitigation(
    FixedIntervalTimeSeries(
        DateTime(config["pvGenProfile"]["DateTime"][1]),
        DateTime(config["pvGenProfile"]["DateTime"][2]) -
        DateTime(config["pvGenProfile"]["DateTime"][1]),
        PeriodSeries(Float64.(config["pvGenProfile"]["Power"])),
    ),
    config["ratedPowerKw"],
)

VariabilityMitigation(config::AbstractDict, tStart::DateTime, tEnd::DateTime) =
    VariabilityMitigation(
        extract(
            FixedIntervalTimeSeries(
                DateTime(config["pvGenProfile"]["DateTime"][1]),
                DateTime(config["pvGenProfile"]["DateTime"][2]) -
                DateTime(config["pvGenProfile"]["DateTime"][1]),
                PeriodSeries(float.(config["pvGenProfile"]["Power"])),
            ),
            tStart,
            tEnd,
        ),
        config["ratedPowerKw"],
    )

use_case_name(ucVM::VariabilityMitigation) = "Power Smoothing"

moving_std(ts::TimeSeries, windowLength::Dates.TimePeriod, samplingRate::Dates.TimePeriod) =
    begin
        tStart = start_time(ts) + windowLength
        # if tStart > end_time(ts)
        #     return FixedIntervalTimeSeries(tStart, samplingRate, [])
        # end

        v = [std(ts, t - windowLength, t) for t = tStart:samplingRate:end_time(ts)]
        return FixedIntervalTimeSeries(tStart, samplingRate, PointSeries(v))
    end

calculate_metrics(sh::TimeFrame, op::TimeFrame, ucVM::VariabilityMitigation) =
    begin
        @debug "Calculating metrics for Power Smoothing"
        netPowerSmooth = extract(
            power(op) - power(sh) + ucVM.pvGenProfile,
            start_time(ucVM.pvGenProfile),
            end_time(ucVM.pvGenProfile),
        )
        originalMaxVariability =
            maximum(moving_std(ucVM.pvGenProfile, Minute(10), ucVM.pvGenProfile.resolution))
        smoothedMaxVariability =
            maximum(moving_std(netPowerSmooth, Minute(10), ucVM.pvGenProfile.resolution))
        mitigatedVariabilityPct = round(
            (originalMaxVariability - smoothedMaxVariability) / originalMaxVariability *
            100;
            sigdigits = 2,
        )

        [
            Dict(:sectionTitle => "Power Smoothing"),
            Dict(
                :label => "Variability Reduction",
                :value => "$(mitigatedVariabilityPct)%",
            ),
            # Dict(:label => "SOC Deviation", :value => "0%"), # TODO: calculate SOC deviation
        ]
    end

use_case_charts(sh::TimeFrame, op::TimeFrame, ucVM::VariabilityMitigation) =
    begin
        @debug "Generating time series charts for Power Smoothing"
        netPowerSmooth = extract(
            power(op) - power(sh) + ucVM.pvGenProfile,
            start_time(ucVM.pvGenProfile),
            end_time(ucVM.pvGenProfile),
        )
        originalVariability =
            moving_std(ucVM.pvGenProfile, Minute(10), ucVM.pvGenProfile.resolution)
        smoothedVariability =
            moving_std(netPowerSmooth, Minute(10), ucVM.pvGenProfile.resolution)

        return [
            Dict(
                :title => "Power Smoothing",
                :height => "350px",
                :xAxis => Dict(:title => "Time"),
                :yAxisLeft => Dict(:title => "Power (kW)"),
                :data => [
                    Dict(
                        :x => timestamps(ucVM.pvGenProfile),
                        :y => raw_vector(ucVM.pvGenProfile),
                        :type => "interval",
                        :name => "Original Power",
                        :line => Dict(:dash => :dash),
                    ),
                    Dict(
                        :x => timestamps(netPowerSmooth),
                        :y => raw_vector(netPowerSmooth),
                        :type => "interval",
                        :name => "Smoothed Power",
                    ),
                ],
            ),
            Dict(
                :height => "300px",
                :xAxis => Dict(:title => "Time"),
                :yAxisLeft => Dict(:title => "Variability (kW)"),
                :data => [
                    Dict(
                        :x => timestamps(originalVariability),
                        :y => raw_vector(originalVariability),
                        :type => "interval",
                        :name => "Original Variability",
                        :line => Dict(:dash => :dash),
                    ),
                    Dict(
                        :x => timestamps(smoothedVariability),
                        :y => raw_vector(smoothedVariability),
                        :type => "interval",
                        :name => "Smoothed Variability",
                    ),
                ],
            ),
        ]
    end