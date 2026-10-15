"""
Piecewise-linear curves for the MESA modes (Volt-Watt, Frequency-Watt curve mode, and the reactive functions later).
X and Y units are whatever the owning mode documents: percent of VRef, percent frequency deviation, percent of WMax.
"""

struct Vertex
    x::Float64
    y::Float64
end
Vertex(xy::Union{Tuple,AbstractVector}) = Vertex(Float64(xy[1]), Float64(xy[2]))

"""
    VertexCurve(vertices)

A curve of `Vertex` points sorted by x with no duplicate x. Also accepts `[(x, y), ...]`, `[[x, y], ...]`, or an
IEC 61850 curve serialised as `Dict("crvPts" => [Dict("xVal" => x, "yVal" => y), ...])`.
"""
struct VertexCurve
    vertices::Vector{Vertex}
    function VertexCurve(vertices::AbstractVector{Vertex})
        isempty(vertices) && throw(ArgumentError("a VertexCurve needs at least one vertex"))
        v = sort(collect(vertices); by = p -> p.x)
        for i = 1:length(v)-1
            v[i].x == v[i+1].x && throw(ArgumentError("duplicate x value $(v[i].x) in VertexCurve"))
        end
        new(v)
    end
end
VertexCurve(points::AbstractVector) = VertexCurve(Vertex[Vertex(pt) for pt in points])
VertexCurve(crv::AbstractDict) =
    VertexCurve(Vertex[Vertex(Float64(pt["xVal"]), Float64(pt["yVal"])) for pt in crv["crvPts"]])

first_x(c::VertexCurve) = c.vertices[1].x
last_x(c::VertexCurve) = c.vertices[end].x

"""
    evaluate_curve(curve, x)

Linear interpolation between vertices; constant extension beyond the first and last vertex.
"""
function evaluate_curve(curve::VertexCurve, x::Real)
    v = curve.vertices
    x <= v[1].x && return v[1].y
    x >= v[end].x && return v[end].y
    for i = 1:length(v)-1
        if x <= v[i+1].x
            slope = (v[i+1].y - v[i].y) / (v[i+1].x - v[i].x)
            return v[i].y + slope * (x - v[i].x)
        end
    end
    return v[end].y
end

"Percent of WMax (y ≥ 0) or of ChaWMax (y < 0) to kW."
pct_to_kw(pct::Real, WMax::Real, ChaWMax::Real) = pct >= 0 ? pct / 100 * WMax : pct / 100 * ChaWMax

"""
    MovingAverage(window)

Time-windowed moving average of samples pushed with `push_sample!`; `average` drops samples older than the window.
"""
mutable struct MovingAverage
    window::Dates.Second
    times::Vector{DateTime}
    values::Vector{Float64}
end
MovingAverage(window) = MovingAverage(Dates.Second(window), DateTime[], Float64[])

function push_sample!(ma::MovingAverage, t::DateTime, v::Real)
    push!(ma.times, t)
    push!(ma.values, Float64(v))
    cutoff = t - ma.window
    while !isempty(ma.times) && ma.times[1] < cutoff
        popfirst!(ma.times)
        popfirst!(ma.values)
    end
    return ma
end

average(ma::MovingAverage) = isempty(ma.values) ? 0.0 : sum(ma.values) / length(ma.values)
reset!(ma::MovingAverage) = (empty!(ma.times); empty!(ma.values); ma)
