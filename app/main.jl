
using AWSS3

if length(ARGS) != 1
    @error "Command line argument INPUT_PATH is required" ARGS
    exit(1)
end

INPUT_PATH = ARGS[1]

dir, inputFilename = splitdir(INPUT_PATH)
JOB_ID, EXT = splitext(inputFilename)

# Abort if file uploaded is not input
if dir != "input" || EXT != ".json"
    @warn "Uploaded file isn't an input. Ignored."
    exit(0)
end


BUCKET_NAME = get(ENV, "BUCKET_NAME", "long-running-jobs-test")
LOG_FILENAME = "log.txt"

@info "Reading input data..."
inputPath = S3Path("s3://$BUCKET_NAME/$INPUT_PATH")
inputFileStat = stat(inputPath)

# Abort if input data is empty
if inputFileStat.size == 0
    error("Input data is empty")
end

@info "Getting output metadata..."
outputPath = S3Path("s3://$BUCKET_NAME/output/$JOB_ID.json")
outputFileStat = stat(outputPath)

# Abort if output data is newer than input
if outputFileStat.mtime > inputFileStat.mtime
    @warn "Corresponding output file is newer than the input.\nAbort."
    exit(0)
end

@info "Starting evaluation..."
open(`julia --project=. evaluation_engine.jl $JOB_ID`) do evaluationStdout
    logString = ""
    logBuffer = String[]
    logTask = @async while !eof(evaluationStdout)
        line = readline(evaluationStdout, keep=true)
        push!(logBuffer, line)
    end

    # Set maximum execution time to 4 hours (14400 seconds)
    maxExecutionTime = 4 * 60 * 60  # 4 hours in seconds
    startTime = time()

    while !istaskdone(logTask)
        # Check if maximum execution time has been exceeded
        if time() - startTime > maxExecutionTime
            @warn "Maximum execution time of 4 hours exceeded. Terminating process."
            kill(evaluationStdout)
            error("Process terminated due to timeout after 4 hours")
        end

        if !isempty(logBuffer)
            logString *= join(logBuffer)
            empty!(logBuffer)
            s3_put(BUCKET_NAME, "$JOB_ID/$LOG_FILENAME", logString)
        end
        sleep(2)
    end

    # Upload last batch of logs
    if !isempty(logBuffer)
        logString *= join(logBuffer)
        empty!(logBuffer)
        s3_put(BUCKET_NAME, "$JOB_ID/$LOG_FILENAME", logString)
    end
end

