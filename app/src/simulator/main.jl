"""
    EnergyStorageSimulators

The `EnergyStorageSimulators` provides type and functions for simulating the operation and behaviors of energy storage systems.
"""
module EnergyStorageSimulators

using Dates

export EnergyStorageSystem,
    MockSimulator,
    LiIonBattery,
    VRFBattery,
    HydrogenEnergyStorageSystem,
    operate!,
    get_ess,
    initialize_operation_history,
    SOC,
    SOH,
    p_max,
    p_min,
    e_max,
    e_min,
    energy_state,
    ηRT,
    self_discharge_rate,
    H2_KWH_PER_KG
using CtrlEvalEngine

abstract type EnergyStorageSystem end

"""
    operate!(ess, powerKw, duration, ambientTemperatureDegreeC) -> actualPowerKw

Operate `ess` with `powerKw` for `duration` while ambient temperature is `ambientTemperatureDegreeC`
and returns the actual charging/discharging power considering operational constraints.
"""
function operate!(
    ess::EnergyStorageSystem,
    powerKw::Real,
    duration::Dates.Period = Hour(1),
    ambientTemperatureDegreeC::Real = 20,
)
    durationHour = /(promote(duration, Hour(1))...)

    if powerKw > p_max(ess, durationHour, ambientTemperatureDegreeC)
        @warn "Operation attempt exceeds power upper bound. Falling back to bound." maxlog =
            10 powerKw upper_bound = p_max(ess, durationHour, ambientTemperatureDegreeC) SOC =
            SOC(ess) SOH = SOH(ess) ambientTemperatureDegreeC
        powerKw = p_max(ess, durationHour, ambientTemperatureDegreeC)
    elseif powerKw < p_min(ess, durationHour, ambientTemperatureDegreeC)
        @warn "Operation attempt exceeds power lower bound. Falling back to bound." maxlog =
            10 powerKw lower_bound = p_min(ess, durationHour, ambientTemperatureDegreeC) SOC =
            SOC(ess) SOH = SOH(ess) ambientTemperatureDegreeC
        powerKw = p_min(ess, durationHour, ambientTemperatureDegreeC)
    end

    return _operate!(ess, powerKw, durationHour, ambientTemperatureDegreeC)
end

"""
    SOH(ess::EnergyStorageSystem)

Calculate the state of health (SOH) of an ESS.
"""
SOH(ess::EnergyStorageSystem) = 1

"""
    p_max(ess::EnergyStorageSystem, duration::Dates.Period, ambientTemperatureDegreeC::Real)

Calculate the maximum power output (positive means discharging, negative means charging)
of `ess` lasting for a time period of `duration`.
"""
function p_max(
    ess::EnergyStorageSystem,
    duration::Dates.Period,
    ambientTemperatureDegreeC::Real = 20,
)
    durationHour = /(promote(duration, Hour(1))...)
    p_max(ess, durationHour, ambientTemperatureDegreeC)
end

"""
    p_min(ess::EnergyStorageSystem, duration::Dates.Period, ambientTemperatureDegreeC::Real)

Calculate the minimum power output (negative means charging, positive means discharging)
of `ess` lasting for a time period of `duration`.
"""
function p_min(
    ess::EnergyStorageSystem,
    duration::Dates.Period,
    ambientTemperatureDegreeC::Real = 20,
)
    durationHour = /(promote(duration, Hour(1))...)
    p_min(ess, durationHour, ambientTemperatureDegreeC)
end

"""
    initialize_operation_history(tStart::Dates.DateTime, ess::EnergyStorageSystem)

Initialize an operation history TimeFrame for tracking the actual operation of an energy storage system.

The operation history contains time-series data of:

  - `:powerKw`: Actual power output/input (PeriodSeries)
  - `:SOC`: State of charge at each time point (PointSeries)
  - Additional ESS-specific columns as determined by `initialize_extra_operations`

# Arguments

  - `tStart`: Starting timestamp for the operation history
  - `ess`: Energy storage system to initialize history for

# Returns

A `TimeFrame` with appropriate columns initialized with the ESS's current state.
"""
function initialize_operation_history(tStart::Dates.DateTime, ess::EnergyStorageSystem)
    extraColumnSeries, extraColumnHeaders = initialize_extra_operations(ess)
    TimeFrame(
        [tStart],
        [PeriodSeries{Float64}(), PointSeries([SOC(ess)]), extraColumnSeries...],
        [:powerKw, :SOC, extraColumnHeaders...],
    )
end

"""
    initialize_extra_operations(ess::EnergyStorageSystem)

Initialize additional operation history columns specific to the energy storage system type.

This function allows different ESS types to add custom tracking columns to their operation history.
The default implementation returns empty collections, but specific ESS types can override this
to add relevant metrics (e.g., hydrogen storage levels, temperature tracking, etc.).

# Arguments

  - `ess`: Energy storage system to initialize extra operations for

# Returns

A tuple `(seriesVector, headersVector)` where:

  - `seriesVector`: Vector of `Series` objects for additional columns
  - `headersVector`: Vector of `Symbol` headers corresponding to the series
"""
initialize_extra_operations(::EnergyStorageSystem) = (Series[], Symbol[])

include("mock-simulator.jl")
include("li-ion-battery.jl")
include("vrf-battery.jl")
include("hydrogen-energy-storage.jl")

"""
    get_ess(input::Dict)

Construct the appropriate EnergyStorageSystem object based on `input`
"""
function get_ess(input::Dict)
    try
        powerCapKw = if lowercase(input["powerCapacityUnit"]) == "kw"
            float(input["powerCapacityValue"])
        elseif lowercase(input["powerCapacityUnit"]) == "mw"
            float(input["powerCapacityValue"]) * 1000
        else
            throw(
                InvalidInput(
                    string(
                        "Unsupported unit for ESS power capacity - ",
                        input["powerCapacityUnit"],
                    ),
                ),
            )
        end

        energyCapKwh = if input["calculationType"] == "duration"
            powerCapKw * float(input["duration"])
        else
            float(input["energyCapacity"])
        end

        ηRT = float(input["roundtripEfficiency"])

        ess = if input["batteryType"] == "lfp-lithium-ion"
            LiIonBattery(
                LFP_LiIonBatterySpecs(
                    powerCapKw,
                    energyCapKwh,
                    ηRT,
                    float(input["cycleLife"]),
                ),
                LiIonBatteryStates(0.5, 0),
            )
        elseif input["batteryType"] == "nmc-lithium-ion"
            LiIonBattery(
                NMC_LiIonBatterySpecs(
                    powerCapKw,
                    energyCapKwh,
                    ηRT,
                    float(input["cycleLife"]),
                ),
                LiIonBatteryStates(0.5, 0),
            )
        elseif input["batteryType"] == "vanadium-flow"
            VRFBattery(
                VRFBatterySpecs(powerCapKw, energyCapKwh, ηRT),
                VRFBatteryStates(0.5 * energyCapKwh),
            )
        elseif input["batteryType"] == "mock"
            MockSimulator(MockES_Specs(powerCapKw, energyCapKwh, ηRT), MockES_States(0.5))
        elseif input["batteryType"] == "hydrogen"
            electrolyzerPowerKw =
                if lowercase(get(input, "electrolyzerRatedPowerUnit", "mw")) == "kw"
                    float(input["electrolyzerRatedPower"])
                elseif lowercase(get(input, "electrolyzerRatedPowerUnit", "mw")) == "mw"
                    float(input["electrolyzerRatedPower"]) * 1000
                else
                    throw(InvalidInput("Unsupported unit for electrolyzer rated power"))
                end

            compressorPowerKw =
                if lowercase(get(input, "compressorRatedPowerUnit", "kw")) == "kw"
                    float(input["compressorRatedPower"])
                elseif lowercase(get(input, "compressorRatedPowerUnit", "kw")) == "mw"
                    float(input["compressorRatedPower"]) * 1000
                else
                    throw(InvalidInput("Unsupported unit for compressor rated power"))
                end

            generationPowerKw =
                if lowercase(get(input, "generationRatedPowerUnit", "mw")) == "kw"
                    float(input["generationRatedPower"])
                elseif lowercase(get(input, "generationRatedPowerUnit", "mw")) == "mw"
                    float(input["generationRatedPower"]) * 1000
                else
                    throw(InvalidInput("Unsupported unit for generation rated power"))
                end

            HydrogenEnergyStorageSystem(
                HydrogenEnergyStorageSpecs(
                    ElectrolyzerSpecs(
                        electrolyzerPowerKw,
                        float(input["electrolyzerElectricityUsage"]),
                        float(input["electrolyzerMinimumLoad"]),
                    ),
                    HydrogenStorageSpecs(
                        float(input["lowPressureStorageCapacity"]),
                        float(input["mediumPressureStorageCapacity"]),
                        float(input["compressorLosses"]),
                        float(input["compressorEnergyConsumptionRate"]),
                        compressorPowerKw,
                    ),
                    FuelCellSpecs(
                        generationPowerKw,
                        float(input["generationEfficiency"]),
                        float(input["generationMinLoadingLevel"]),
                        float(input["generationOperatingLifetime"]),
                    ),
                ),
                HydrogenEnergyStorageStates(
                    float(input["lowPressureStorageCapacity"]) * 0.5,
                    float(input["mediumPressureStorageCapacity"]) * 0.5,
                    false,
                    false,
                    false,
                ),
            )
        else
            throw(InvalidInput(string("Unsupported ESS type - ", input["batteryType"])))
        end
        return ess
    catch e
        if e isa KeyError
            throw(InvalidInput("Missing key in ESS parameter - \"$(e.key)\""))
        else
            rethrow()
        end
    end
end

end