using Test, LibTmuxMCP, ModelContextProtocol
const Protocol = ModelContextProtocol

@testset "bounded stdio framing" begin
    transport = LibTmuxMCP._StdioTransport(
        IOBuffer("{}\n{\"a\":1}\r\n"),
        IOBuffer();
        max_input_bytes=8,
    )
    @test Protocol.read_message(transport) == "{}"
    @test Protocol.read_message(transport) == "{\"a\":1}\r"
    @test Protocol.read_message(transport) === nothing
    Protocol.close(transport)
    @test !Protocol.is_connected(transport)

    input = IOBuffer(repeat("x", 100))
    transport = LibTmuxMCP._StdioTransport(input, IOBuffer(); max_input_bytes=8)
    @test_throws LibTmuxMCP.StdioFramingError Protocol.read_message(transport)
    @test position(input) == 9
    Protocol.close(transport)

    transport = LibTmuxMCP._StdioTransport(IOBuffer("{}"), IOBuffer())
    @test_throws LibTmuxMCP.StdioFramingError Protocol.read_message(transport)
    Protocol.close(transport)
    transport = LibTmuxMCP._StdioTransport(IOBuffer(UInt8[0xff, 0x0a]), IOBuffer())
    @test_throws LibTmuxMCP.StdioFramingError Protocol.read_message(transport)
    Protocol.close(transport)

    output = IOBuffer()
    transport = LibTmuxMCP._StdioTransport(IOBuffer(), output)
    Protocol.write_message(transport, "{}")
    @test String(take!(output)) == "{}\n"
    @test_throws LibTmuxMCP.StdioFramingError Protocol.write_message(transport, "{}\n{}")
    Protocol.close(transport)
    @test_throws EOFError Protocol.write_message(transport, "{}")
end

@testset "owned stdio pipes close pending I/O" begin
    input, output = Pipe(), Pipe()
    Base.link_pipe!(input; reader_supports_async=true, writer_supports_async=true)
    Base.link_pipe!(output; reader_supports_async=true, writer_supports_async=true)
    transport = LibTmuxMCP._StdioTransport(
        IOContext(input.out, :color=>false),
        IOContext(output, :color=>false),
    )
    reading = Threads.@spawn Protocol.read_message(transport)
    entered = Base.Event()
    writing = Threads.@spawn begin
        notify(entered)
        try
            Protocol.write_message(transport, repeat("x", 1024^2))
        catch error
            error
        end
    end
    try
        wait(entered)
        # Consuming one byte proves the large write reached the full pipe.
        @test read(output.out, UInt8) == UInt8('x')
        Protocol.close(transport)
        @test fetch(reading) === nothing
        @test fetch(writing) isa EOFError
        @test !isopen(input.out) && !isopen(output.in) && !isopen(output.out)
    finally
        Protocol.close(transport)
        close(input)
        close(output)
        wait(reading)
        wait(writing)
    end
end
