
using JSON
using CtrlEvalEngine
using AWSS3

redirect_stdio(; stderr = stdout)
BUCKET_NAME = get(ENV, "BUCKET_NAME", "long-running-jobs-test")

inputDict, debug, JOB_ID = if length(ARGS) == 1
    inputJobId = ARGS[1]
    (
        JSON.parse(
            IOBuffer(read(S3Path("s3://$BUCKET_NAME/input/$inputJobId.json")));
            dicttype = Dict,
        ),
        false,
        inputJobId,
    )
elseif length(ARGS) == 2 && ARGS[1] == "debug"
    (JSON.parsefile(ARGS[2]; dicttype = Dict), true, nothing)
else
    @error "Unsupported command line arguments" ARGS
    exit(1)
end

outputDict = try
    evaluate_controller(inputDict, BUCKET_NAME, JOB_ID; debug)
catch e
    if debug
        throw(e)
    end
    bt = catch_backtrace()
    if isa(e, InvalidInput)
        @error("Invalid input", exception = (e, bt))
    elseif e isa InitializationFailure
        @error("Failed to initialize a scheduler or real-time controller", exception = (e, bt))
    else
        @error("Something went wrong during evaluation", exception = (e, bt))
    end
    strIO = IOBuffer()
    show(strIO, "text/plain", stacktrace(bt))
    strST = String(take!(strIO))
    Dict(:error => string(e), :stacktrace => strST)
end

if debug
    open(ARGS[2][1:end-5] * "_output.json", "w") do f
        JSON.print(f, outputDict, 4)
    end
else
    if haskey(outputDict, :error)
        @warn "Error occurred. Uploading info for debugging"
        s3_copy(BUCKET_NAME, "input/$JOB_ID.json"; to_path = "error/$JOB_ID/input.json")
        s3_put(BUCKET_NAME, "error/$JOB_ID/output.json", JSON.json(outputDict, 4))
        s3_put(BUCKET_NAME, "error/$JOB_ID/stacktrace.txt", outputDict[:stacktrace])
    end

    @info "Uploading output data"
    s3_put(BUCKET_NAME, "output/$JOB_ID.json", JSON.json(outputDict))
end
@info "Exiting"
