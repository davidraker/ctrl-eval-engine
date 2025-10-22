struct ElectrolyzerSpecs
    ratedPowerKw::Float64
    electricityPowerKwhPerKg::Float64
    minLoadPu::Float64
end

struct HydrogenStorageSpecs
    lowPressureTankSizeKg::Float64
    mediumPressureTankSizeKg::Float64
    compressionLossPu::Float64
    compressorKwhPerKg::Float64
    compressorRatedPowerKw::Float64
end

struct FuelCellSpecs
    ratedPowerKw::Float64
    efficiencyPu::Float64
    minLoadingPu::Float64
    operatingLifetimeHour::Float64
end

struct WaterCostSpecs
    waterCostChargeRateDollarsPerKgal::Float64
    waterCostDrainageChargeRateDollarsPerKgal::Float64
    waterCostMinimumChargeDollars::Float64
    waterCostThresholdKgal::Float64
end

struct HydrogenEnergyStorageSpecs
    electrolyzerSpecs::ElectrolyzerSpecs
    hydrogenStorageSpecs::HydrogenStorageSpecs
    fuelCellSpecs::FuelCellSpecs
end

mutable struct HydrogenEnergyStorageStates
    lowPressureH2Kg::Float64
    mediumPressureH2Kg::Float64
    electrolyzerOn::Bool
    fuelCellOn::Bool
    compressorOn::Bool
end

struct HydrogenEnergyStorageSystem <: EnergyStorageSystem
    specs::HydrogenEnergyStorageSpecs
    states::HydrogenEnergyStorageStates
end

const H2_KWH_PER_KG = 39.39

function _operate!(
    hess::HydrogenEnergyStorageSystem,
    powerKw::Real,
    durationHour::Real,
    _::Real,
)
    if powerKw > 0
        h2_needed =
            powerKw * durationHour / (hess.specs.fuelCellSpecs.efficiencyPu * H2_KWH_PER_KG)

        h2_from_lp = min(h2_needed, hess.states.lowPressureH2Kg)
        hess.states.lowPressureH2Kg -= h2_from_lp

        if h2_from_lp < h2_needed
            h2_from_mp = min(h2_needed - h2_from_lp, hess.states.mediumPressureH2Kg)
            hess.states.mediumPressureH2Kg -= h2_from_mp
        end

        hess.states.fuelCellOn = true
        hess.states.electrolyzerOn = false
        hess.states.compressorOn = false
    else
        powerKw, h2ToLp, hm = compute_charge_power(hess, powerKw, durationHour)

        if hm > 0
            hess.states.compressorOn = true
        else
            hess.states.compressorOn = false
        end

        hess.states.lowPressureH2Kg += h2ToLp
        hess.states.mediumPressureH2Kg += hm

        if h2ToLp > 0 || hm > 0
            hess.states.electrolyzerOn = true
        end

        hess.states.fuelCellOn = false
    end

    @debug "operating hess" powerKw hess.states

    return (;
        powerKw,
        SOC = SOC(hess),
        storedHydrogenKg = hess.states.lowPressureH2Kg + hess.states.mediumPressureH2Kg,
    )
end

initialize_extra_operations(hes::HydrogenEnergyStorageSystem) = (
    [PointSeries([hes.states.lowPressureH2Kg + hes.states.mediumPressureH2Kg])],
    [:storedHydrogenKg],
)

function compute_charge_power(hess::HydrogenEnergyStorageSystem, powerKw, durationHour)
    h2Produced =
        (-powerKw * durationHour) / hess.specs.electrolyzerSpecs.electricityPowerKwhPerKg

    spaceInLp =
        hess.specs.hydrogenStorageSpecs.lowPressureTankSizeKg - hess.states.lowPressureH2Kg
    h2ToLp = min(h2Produced, spaceInLp)

    if h2ToLp < h2Produced
        time_to_fill_lp =
            (hess.specs.electrolyzerSpecs.electricityPowerKwhPerKg * h2ToLp) / -powerKw

        remaining_duration = durationHour - time_to_fill_lp

        hp =
            (
                (-powerKw * remaining_duration) /
                hess.specs.hydrogenStorageSpecs.compressorKwhPerKg
            ) / (
                1 + (
                    hess.specs.electrolyzerSpecs.electricityPowerKwhPerKg /
                    hess.specs.hydrogenStorageSpecs.compressorKwhPerKg
                )
            )

        pc =
            (
                (-powerKw * remaining_duration) -
                (hp * hess.specs.electrolyzerSpecs.electricityPowerKwhPerKg)
            ) / remaining_duration

        hm = hp * (1 - hess.specs.hydrogenStorageSpecs.compressionLossPu)

        ratioM = min(
            1,
            (
                hess.specs.hydrogenStorageSpecs.mediumPressureTankSizeKg -
                hess.states.mediumPressureH2Kg
            ) / hm,
        )

        ratioP = min(1, hess.specs.hydrogenStorageSpecs.compressorRatedPowerKw / pc)

        ratio = min(ratioM, ratioP)

        if ratio < 1
            hp *= ratio
            pc *= ratio

            pe =
                hp * hess.specs.electrolyzerSpecs.electricityPowerKwhPerKg /
                remaining_duration

            # pe = pe < (hess.specs.electrolyzerSpecs.minLoadPu * hess.specs.electrolyzerSpecs.ratedPowerKw) ?
            #      0.0 : min_power

            p = pe + pc

            powerKw = (powerKw * time_to_fill_lp - p * remaining_duration) / durationHour

            hm *= ratio
        end

        return (powerKw, h2ToLp, hm)
    else
        return (powerKw, h2ToLp, 0)
    end
end

function SOC(hess::HydrogenEnergyStorageSystem)
    total_h2 = hess.states.lowPressureH2Kg + hess.states.mediumPressureH2Kg
    total_capacity =
        hess.specs.hydrogenStorageSpecs.lowPressureTankSizeKg +
        hess.specs.hydrogenStorageSpecs.mediumPressureTankSizeKg
    return total_h2 / total_capacity
end

function energy_state(hess::HydrogenEnergyStorageSystem)
    total_h2 = hess.states.lowPressureH2Kg + hess.states.mediumPressureH2Kg
    return total_h2 * H2_KWH_PER_KG * hess.specs.fuelCellSpecs.efficiencyPu
end

function p_max(hess::HydrogenEnergyStorageSystem, durationHour::Real, _::Real)
    total_h2 = hess.states.lowPressureH2Kg + hess.states.mediumPressureH2Kg
    available_energy = total_h2 * H2_KWH_PER_KG * hess.specs.fuelCellSpecs.efficiencyPu
    max_power = min(hess.specs.fuelCellSpecs.ratedPowerKw, available_energy / durationHour)

    return max_power <
           (hess.specs.fuelCellSpecs.minLoadingPu * hess.specs.fuelCellSpecs.ratedPowerKw) ?
           0.0 : max_power
end

function p_max(hess::HydrogenEnergyStorageSystem)
    return hess.specs.fuelCellSpecs.ratedPowerKw
end

# TODO: change
function p_min(hess::HydrogenEnergyStorageSystem, durationHour::Real, _::Real)
    powerKw, _, _ =
        compute_charge_power(hess, -hess.specs.electrolyzerSpecs.ratedPowerKw, durationHour)

    return powerKw
end

function p_min(hess::HydrogenEnergyStorageSystem)
    return -hess.specs.electrolyzerSpecs.ratedPowerKw
end

function e_max(hess::HydrogenEnergyStorageSystem)
    total_capacity = (
        hess.specs.hydrogenStorageSpecs.lowPressureTankSizeKg +
        hess.specs.hydrogenStorageSpecs.mediumPressureTankSizeKg
    )
    return total_capacity * H2_KWH_PER_KG * hess.specs.fuelCellSpecs.efficiencyPu
end

function e_min(::HydrogenEnergyStorageSystem)
    return 0.0
end

function ηRT(hess::HydrogenEnergyStorageSystem)
    return (
        (1 - hess.specs.hydrogenStorageSpecs.compressionLossPu) *
        hess.specs.fuelCellSpecs.efficiencyPu *
        H2_KWH_PER_KG
    ) / (
        hess.specs.electrolyzerSpecs.electricityPowerKwhPerKg +
        hess.specs.hydrogenStorageSpecs.compressorKwhPerKg
    )
end

function self_discharge_rate(::HydrogenEnergyStorageSystem)
    return 0.0
end
