using CtrlEvalEngine

"""
    VoltageControl(meteredVoltage, referenceVoltage)

Metered voltage at the ESS's reference point and its nominal value (same unit), the input of the Volt-Watt and
Dynamic Volt-Watt functions.
"""
struct VoltageControl <: UseCase
    meteredVoltage::TimeSeries
    referenceVoltage::Float64
end

"""
    VoltageControl(input::AbstractDict[, tStart, tEnd])

From `{"meteredVoltage": {"DateTime": [...], "Voltage": [...]}, "referenceVoltage": 120}`.
"""
VoltageControl(input::AbstractDict) = VoltageControl(
    FixedIntervalTimeSeries(
        DateTime(input["meteredVoltage"]["DateTime"][1]),
        DateTime(input["meteredVoltage"]["DateTime"][2]) - DateTime(input["meteredVoltage"]["DateTime"][1]),
        float.(input["meteredVoltage"]["Voltage"]),
    ),
    float(input["referenceVoltage"]),
)

VoltageControl(input::AbstractDict, tStart::DateTime, tEnd::DateTime) = begin
    uc = VoltageControl(input)
    VoltageControl(extract(uc.meteredVoltage, tStart, tEnd), uc.referenceVoltage)
end

use_case_name(::VoltageControl) = "Voltage Control"
