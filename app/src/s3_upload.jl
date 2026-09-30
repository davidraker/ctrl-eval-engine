# HTTP.jl does not retry TLSError("connection is closed"). After the results
# are built, a pooled S3 connection is often already dropped, and one PutObject
# of a cell-level result dies on that read. Parts stay at or above S3's 5 MiB
# minimum except the last part. A closed connection is tried again.
const S3_UPLOAD_ATTEMPTS = 4
const S3_PART_BYTES = 8 * 1024 * 1024
const S3_SINGLE_PUT_MAX = 5 * 1024 * 1024

function s3_connection_closed(err)::Bool
    current = err
    seen = IdDict{Any,Nothing}()
    for _ in 1:12
        current === nothing && return false
        haskey(seen, current) && return false
        seen[current] = nothing
        text = try
            lowercase(sprint(showerror, current))
        catch
            ""
        end
        if occursin("connection is closed", text) ||
           occursin("connection reset", text) ||
           occursin("econnreset", text) ||
           occursin("broken pipe", text) ||
           occursin("unexpected eof", text)
            return true
        end
        current = _exception_cause(current)
    end
    return false
end

function _exception_cause(err)
    for name in (:cause, :err)
        hasproperty(err, name) || continue
        value = getproperty(err, name)
        value isa Exception && return value
    end
    return nothing
end

function s3_part_ranges(nbytes::Integer, part_size::Integer)
    nbytes < 0 && throw(ArgumentError("nbytes must be >= 0"))
    part_size < 1 && throw(ArgumentError("part_size must be >= 1"))
    ranges = UnitRange{Int}[]
    start = 1
    n = Int(nbytes)
    while start <= n
        stop = min(start + Int(part_size) - 1, n)
        push!(ranges, start:stop)
        start = stop + 1
    end
    return ranges
end

function _retry_closed_connection(f, what)
    for attempt in 1:S3_UPLOAD_ATTEMPTS
        try
            return f()
        catch err
            if attempt == S3_UPLOAD_ATTEMPTS || !s3_connection_closed(err)
                rethrow()
            end
            @warn "S3 connection closed; retrying" request=what attempt exception=err
            sleep(min(8.0, 0.5 * 2.0^(attempt - 1)))
        end
    end
    error("S3 upload retry ended without a result")
end

function _abort_multipart(aws, upload)
    upload === nothing && return nothing
    try
        AWSS3.S3.abort_multipart_upload(
            upload["Bucket"],
            upload["Key"],
            upload["UploadId"];
            aws_config = aws,
        )
    catch err
        @warn "Failed to abort the S3 multipart upload" exception=err
    end
    return nothing
end

function upload_s3_text(bucket, path, payload::AbstractString)
    if sizeof(payload) <= S3_SINGLE_PUT_MAX
        _retry_closed_connection("put $path") do
            s3_put(bucket, path, String(payload))
        end
        return nothing
    end

    aws = global_aws_config()
    upload = _retry_closed_connection("begin multipart $path") do
        s3_begin_multipart_upload(aws, bucket, path)
    end
    try
        tags = String[]
        bytes = codeunits(payload)
        for (number, range) in enumerate(s3_part_ranges(sizeof(payload), S3_PART_BYTES))
            chunk = Vector{UInt8}(bytes[range])
            push!(tags, _retry_closed_connection("part $number of $path") do
                s3_upload_part(aws, upload, number, chunk)
            end)
        end
        _retry_closed_connection("complete multipart $path") do
            s3_complete_multipart_upload(aws, upload, tags)
        end
    catch
        _abort_multipart(aws, upload)
        rethrow()
    end
    return nothing
end
