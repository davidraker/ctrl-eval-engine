struct ClosedConnection <: Exception
    cause::Union{Nothing,Exception}
end
Base.showerror(io::IO, ::ClosedConnection) =
    print(io, "tls read failed: connection is closed")

struct OuterFailure <: Exception
    cause::Exception
end
Base.showerror(io::IO, ::OuterFailure) = print(io, "outer failure")

@testset "S3 upload" begin
    @test CtrlEvalEngine.s3_connection_closed(ClosedConnection(nothing))
    @test CtrlEvalEngine.s3_connection_closed(OuterFailure(ClosedConnection(nothing)))
    @test !CtrlEvalEngine.s3_connection_closed(ErrorException("not a transport failure"))

    ranges = CtrlEvalEngine.s3_part_ranges(20, 8)
    @test ranges == [1:8, 9:16, 17:20]
    @test isempty(CtrlEvalEngine.s3_part_ranges(0, 8))
    @test CtrlEvalEngine.s3_part_ranges(5, 8) == [1:5]
    @test_throws ArgumentError CtrlEvalEngine.s3_part_ranges(-1, 8)

    # Every part but the last stays at the 8 MiB part size, above S3's 5 MiB minimum.
    big = CtrlEvalEngine.s3_part_ranges(
        CtrlEvalEngine.S3_PART_BYTES * 2 + 10,
        CtrlEvalEngine.S3_PART_BYTES,
    )
    @test length.(big)[1:end-1] == fill(CtrlEvalEngine.S3_PART_BYTES, length(big) - 1)
    @test length(big[end]) == 10
end
