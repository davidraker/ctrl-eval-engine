
import Base: *, zero
struct RegulationPricePoint
    capacityPrice::Float64
    servicePrice::Float64
end

Base.:zero(::RegulationPricePoint) = RegulationPricePoint(0, 0)
Base.:zero(::Type{RegulationPricePoint}) = RegulationPricePoint(0, 0)

struct RegulationOperationPoint{
    TC<:Union{Real,JuMP.AbstractJuMPScalar},
    TM<:Union{Real,JuMP.AbstractJuMPScalar},
}
    capacity::TC
    mileage::TM
end

Base.:zero(
    ::RegulationOperationPoint{TC,TM},
) where {TC<:Union{Real,JuMP.AbstractJuMPScalar},TM<:Union{Real,JuMP.AbstractJuMPScalar}} =
    RegulationOperationPoint(zero(TC), zero(TM))

Base.:zero(
    ::Type{RegulationOperationPoint{TC,TM}},
) where {TC<:Union{Real,JuMP.AbstractJuMPScalar},TM<:Union{Real,JuMP.AbstractJuMPScalar}} =
    RegulationOperationPoint(zero(TC), zero(TM))

struct Regulation <: UseCase
    AGCSignalPu::TimeSeries{Float64}
    price::FixedIntervalTimeSeries{
        <:Dates.TimePeriod,
        RegulationPricePoint,
        PeriodSeries{RegulationPricePoint},
    }
    performanceScore::Float64
end

Regulation(input::Dict, tStart::DateTime, tEnd::DateTime) = begin
    agcSignalDict = input["data"]["agcSignal"]
    agcCore = FixedIntervalTimeSeries(
        DateTime(agcSignalDict["DateTime"][1]),
        DateTime(agcSignalDict["DateTime"][2]) - DateTime(agcSignalDict["DateTime"][1]),
        PeriodSeries(float.(agcSignalDict["Dispatch_pu"])),
    )
    @debug "Constructing Regulation object" agcSignalDict
    regPriceDict = input["data"]["regulationPrices"]
    regPriceCapacity =
        if input["inputs"]["regulationPrices"]["optionSelected"] == "Wholesale Market"
            regPriceDict["RegUp"]
        else
            regPriceDict["CapacityPrice_per_MW"]
        end

    regPriceMileage =
        if input["inputs"]["regulationPrices"]["optionSelected"] == "Wholesale Market"
            zeros(length(regPriceCapacity))
        else
            regPriceDict["MileagePrice_per_MW"]
        end
    Regulation(
        if get(agcSignalDict, "repeated", false)
            RepeatedTimeSeries(agcCore, tStart, tEnd)
        else
            extract(agcCore, tStart, tEnd)
        end,
        extract(
            FixedIntervalTimeSeries(
                DateTime(regPriceDict["Time"][1]),
                DateTime(regPriceDict["Time"][2]) - DateTime(regPriceDict["Time"][1]),
                PeriodSeries([
                    RegulationPricePoint(cap / 1000, mil / 1000) for
                    (cap, mil) in zip(regPriceCapacity, regPriceMileage)
                ]),
            ),
            tStart,
            tEnd,
        ),
        input["data"]["performanceFactor"],
    )
end

use_case_name(ucReg::Regulation) = "Frequency Regulation"

function regulation_income(
    regOperation::TimeSeries{<:RegulationOperationPoint},
    ucReg::Regulation,
)
    (ucReg.price ⋅ regOperation) * ucReg.performanceScore
end

Base.:*(pp::RegulationPricePoint, op::RegulationOperationPoint) =
    pp.capacityPrice * op.capacity + pp.servicePrice * op.capacity * op.mileage
Base.:*(op::RegulationOperationPoint, pp::RegulationPricePoint) =
    pp.capacityPrice * op.capacity + pp.servicePrice * op.capacity * op.mileage

function regulation_history(sh::TimeFrame, ucReg::Regulation)
    VariableIntervalTimeSeries(
        sh.t,
        [
            RegulationOperationPoint(
                cap,
                sum(abs.(diff(get_values(ucReg.AGCSignalPu, t1, t2).vec))),
            ) for (cap, t1, t2) in sh[:regCapKw]
        ],
    )
end

initialize_extra_schedules(::Regulation) = [(PeriodSeries{Float64}(), :regCapKw)]

calculate_net_benefit(progress::Progress, ucReg::Regulation) = begin
    @debug "Calculating Regulation benefit" schedule = progress.schedule regHistory =
        regulation_history(progress.schedule, ucReg) regPriceLen = length(ucReg.price)
    regulation_income(regulation_history(progress.schedule, ucReg), ucReg)
end

function calculate_metrics(sh::TimeFrame, op::TimeFrame, ucReg::Regulation)
    regIncome = regulation_income(regulation_history(sh, ucReg), ucReg)
    tsError = ucReg.AGCSignalPu * sh[:regCapKw] - (power(op) - power(sh))
    rmse = round(sqrt(mean(tsError^2)); sigdigits = 2)
    return [
        Dict(:sectionTitle => "Frequency Regulation"),
        Dict(:label => "Revenue", :value => regIncome, :type => "currency"),
        Dict(:label => "AGC Signal Following RMSE", :value => "$rmse kW"),
    ]
end

function use_case_charts(sh::TimeFrame, op::TimeFrame, ucReg::Regulation)
    scaledAgcSignal = ucReg.AGCSignalPu * sh[:regCapKw]
    actualRegPower = power(op) - power(sh)
    [
        Dict(
            :title => "Frequency Regulation",
            :height => "300px",
            :yAxisLeft => Dict(:title => "Power (kW)"),
            :yAxisRight => Dict(:title => raw"Price ($/kWh)"),
            :data => [
                Dict(
                    :x => timestamps(sh),
                    :y => get_values(sh[:regCapKw]).vec,
                    :type => "interval",
                    :name => "Scheduled Capacity",
                ),
                Dict(
                    :x => timestamps(ucReg.price),
                    :y => map(
                        (pricePoint::RegulationPricePoint) -> pricePoint.capacityPrice,
                        get_values(ucReg.price),
                    ),
                    :type => "interval",
                    :name => "Regulation Capacity Price",
                    :yAxis => "right",
                ),
                Dict(
                    :x => timestamps(ucReg.price),
                    :y => map(
                        (pricePoint::RegulationPricePoint) -> pricePoint.servicePrice,
                        get_values(ucReg.price),
                    ),
                    :type => "interval",
                    :name => "Mileage Price",
                    :yAxis => "right",
                ),
            ],
        ),
        Dict(
            :height => "300px",
            :xAxis => Dict(:title => "Time"),
            :yAxisLeft => Dict(:title => "Power (kW)"),
            :data => [
                Dict(
                    :x => timestamps(scaledAgcSignal),
                    :y => get_values(scaledAgcSignal),
                    :type => "interval",
                    :line => Dict(:dash => :dot),
                    :name => "AGC Signal",
                ),
                Dict(
                    :x => timestamps(actualRegPower),
                    :y => get_values(actualRegPower),
                    :type => "interval",
                    :name => "Actual Power",
                ),
            ],
        ),
    ]
end