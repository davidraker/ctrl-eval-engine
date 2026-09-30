"""
Test sets for control evaluation engine and individual controllers
"""

using Test

using CtrlEvalEngine

include("s3-upload-tests.jl")
include("timeseries-tests.jl")
include("input-tests.jl")
include("simulator-tests.jl")
include("cell-level-tests.jl")
include("use-case-tests.jl")
include("scheduler-tests.jl")
include("controller-tests.jl")
