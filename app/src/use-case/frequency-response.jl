using CtrlEvalEngine

"""
    FrequencyResponse(meteredFrequency, nominalFrequency)

Metered grid frequency (Hz) at the ESS's reference point, the input of the Frequency-Watt functions.
"""
struct FrequencyResponse <: UseCase
    meteredFrequency::TimeSeries
    nominalFrequency::Float64
end

"""
    FrequencyResponse(input::AbstractDict[, tStart, tEnd])

From `{"meteredFrequency": {"DateTime": [...], "Frequency": [...]}, "nominalFrequency": 60}`.
"""
FrequencyResponse(input::AbstractDict) = FrequencyResponse(
    FixedIntervalTimeSeries(
        DateTime(input["meteredFrequency"]["DateTime"][1]),
        DateTime(input["meteredFrequency"]["DateTime"][2]) - DateTime(input["meteredFrequency"]["DateTime"][1]),
        float.(input["meteredFrequency"]["Frequency"]),
    ),
    float(get(input, "nominalFrequency", 60.0)),
)

FrequencyResponse(input::AbstractDict, tStart::DateTime, tEnd::DateTime) = begin
    uc = FrequencyResponse(input)
    FrequencyResponse(extract(uc.meteredFrequency, tStart, tEnd), uc.nominalFrequency)
end

use_case_name(::FrequencyResponse) = "Frequency Response"
