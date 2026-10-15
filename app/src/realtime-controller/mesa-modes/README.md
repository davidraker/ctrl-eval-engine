# MESA control modes

The `MesaController` (`../mesa.jl`) implements the active power functions of IEEE Std 1815.2-2025 (the DNP3 DER
profile that carries the MESA-ESS functions) for one energy storage system. This file summarises how the modes
combine, their shared parameters, response limiting, units and names, inputs, configuration and status.

## How modes combine (clause 7.3, Table 58)

Modes are not summed. Every mode has a *kind*:

| Kind | Modes | Rule |
|---|---|---|
| Replacing | Charge/Discharge Storage, AGC, Coordinated Charge/Discharge | The highest-priority active one sets the base power (`ModPrio` 0 is highest; ties go to the most recently activated). With none active the base is the schedule period's power. |
| Additive | Frequency-Watt (all three), Volt-Watt, Dynamic Volt-Watt, Smoothing, Load Following, Generation Following | Added to the base. All additions of the best priority group apply; lower groups are suppressed. |
| Bounding | Active Power Limit, Peak Power Limiting | The intersection of their intervals clamps the result, regardless of priority. |

After the bounds come the storage-wide reserves (`SocUseMinPct`/`SocUseMaxPct` on the controller), the device maximum
ramp rates (`maxRampRates`, DCTE), the device power limits and energy feasibility.

AGC is mutually exclusive with every active power function except Charge/Discharge and Active Power Limit; a
conflicting construction or `enable!` raises `ModeConflictError`.

## Shared parameters (6.1.2)

`MesaModeParams(ModPrio; ModEna=true, WinTms=0, RmpTms=0, RvrtTms=0)`. `WinTms` delays the start to a random moment
inside the window (seeded by the controller's `randomSeed`; the end of the window when unseeded); `RmpTms` blends the
mode's contribution linearly from the power it started at; `RvrtTms` disables the mode that long after it started.
`enable!(controller, mode, t)` / `disable!(controller, mode)` change a mode at run time.

## Response limiting (6.1.5, 6.1.6, Tables 22 and 23)

`RampParams(; RpuRte, RpdRte, RpuChaRte, RpdChaRte, RmpUpTms, RmpDnTms)`: ramp rates in percent per second of
`WMax` (discharging) or `ChaWMax` (charging), applied per step; time constants interpreted per the controller's
`OpnLoopTau` (open-loop response time to `OplPct` of the change, or a 3 τ first-order filter). Each function applies
what Table 23 gives it (`response_limiting(mode)`), then the controller applies the device maxima.

## Units and names

Engineering units everywhere: kW, percent, percent per second, Hz, volts (with `VRef`), seconds. Field names are the
IEC 61850-7-420 data objects that IEEE 1815.2 maps its points to, so a configuration keyed by those names maps onto a
mode field by field. The earlier camelCase names map as follows:

| Old name | New field | Logical node |
|---|---|---|
| `priority` | `params.ModPrio` | common |
| `timeWindow`, `rampTime`, `reversionTimeout` | `params.WinTms`, `params.RmpTms`, `params.RvrtTms` | common |
| `dischargeRampUpRate`, `dischargeRampDownRate` | `RampParams.RpuRte`, `RpdRte` | per function |
| `chargeRampUpRate`, `chargeRampDownRate` | `RampParams.RpuChaRte`, `RpdChaRte` | per function |
| `rampUpTimeConstant`, `rampDownTimeConstant` | `RampParams.RmpUpTms`, `RmpDnTms` | per function |
| `activePowerTarget` (percent) | `GnWPctSpt`; kW target `WSpt` | DWGC |
| `rampOrTimeConstant` | `UseRmpRte` | DWGC, DAGC |
| `minimumReservePercent`, `maximumReservePercent` | controller `SocUseMinPct`, `SocUseMaxPct` | DWGC (storage-wide) |
| `maximumDischargePercentage`, `maximumChargePercentage` | `LimWMax`, `LimWMin` (signed interval) | DWMX.LimW, DWMN.LimW |
| `minimumUsableSOC`, `maximumUsableSOC` | `SocUseMinPct`, `SocUseMaxPct` | DAGC |
| `highStartingFrequency`, `highStoppingFrequency` | `HzStrHi`, `HzStopHi` | DHFW.HzStr, DHFW.HzStop |
| `lowStartingFrequency`, `lowStoppingFrequency` | `HzStrLo`, `HzStopLo` | DLFW.HzStr, DLFW.HzStop |
| `highDischargeGradient`, `highChargeGradient` | `WGraHi`, `WChaGraHi` | DHFW.WGra, DHFW.WChaGra |
| `lowDischargeGradient`, `lowChargeGradient` | `WGraLo`, `WChaGraLo` | DLFW.WGra, DLFW.WChaGra |
| `startDelay`, `stopDelay` | `ActStrDlTmms`, `ActStopDlTmms` | DHFW |
| `useSnapshotPower`, `useHysteresis` | `SnptEna`, `HysEna` | DHFW |
| `frequencyWattCurve` | `HzWCrv` (FrequencyWattCurveMode) | DHFW.HzWCrv |
| `highReturnGradient`, `lowReturnGradient` | `RtnRmpRte` | DHFW.RtnRmpRte |
| `voltWattCurve`, `referenceVoltageOffset` | `VWCrv` (+ `VWCrvLo`), `VRefOfs` | DVWC |
| `gradient`, `lowerDeadband`, `upperDeadband`, `filterTime` (dynamic) | `DynVWGra`, `DbVWLo`, `DbVWHi`, `VWFilTms` | DVWD |
| `smoothingGradient`, `lowerSmoothingLimit`, `upperSmoothingLimit`, `smoothingFilterTime` | `WSmthGra`, `WSmthLoLim`, `WSmthHiLim`, `FilTms` | DWSM |
| `activationThreshold`, `outputRatio` | `FolWThr`, `FolWPct` | DWFL1..3 |
| (signal meter) | `EcpRef` | DWMX, DHFW, DVWC, DWSM, DWFL |

## Inputs

A mode reads its signal (`:W`, `:V`, `:Hz`) from the controller's `meters[mode.EcpRef]` (`MeterReadings`, time series
for simulation or live values set with `set_reading!`) and falls back to the use cases: `FrequencyResponse`,
`VoltageControl`, and the power-carrying use cases in the order given by `power_sources(typeof(mode))`.

## Configuration

`"rtController": {"type": "mesa", ...}`; see the docstring of `../mesa-config.jl` for the schema. Use cases
`Frequency Response`, `Voltage Control` and `Peak Limiting` supply the signals in a simulation.

## Status

`mesa_status(controller)` returns the last tick's `MesaStatus`: output, base and which mode set it, per-mode
enabled/active/suppressed flags and attempted outputs (the DWGC.ReqW / DVWC.ReqWLim / DWFL.ReqW read-backs), the
binding bounds, and which stage (bounds, reserves, ramp, device) limited the output.

## Not yet implemented

Reactive power functions (DVAR, DFPF, DVVR, DWVR) and the ride-through overrides need a reactive capability on
`EnergyStorageSystem` first; the `upstream/reactive-emergency-modes` branch holds parameter drafts for them.
