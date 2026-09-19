@testset "strict and streaming UTF-8" begin
    @test isdefined(LibTmux, :decode_text)
    @test isdefined(LibTmux, :TextDecoder)
    if isdefined(LibTmux, :decode_text) && isdefined(LibTmux, :TextDecoder)
        decode = LibTmux.decode_text
        Decoder = LibTmux.TextDecoder
        feed! = LibTmux.decode!
        InvalidUTF8 = LibTmux.InvalidUTF8Error

        valid = [
            "",
            "A",
            "¢",
            "€",
            "𐍈",
            "\ufeffA¢€𐍈\0 \t\r\n",
            "\u007f\u0080\u07ff\u0800\u0fff\u1000\ucfff\ud000" *
            "\ud7ff\ue000\uffff\U00010000\U0003ffff\U00040000" *
            "\U000fffff\U00100000\U0010ffff",
        ]
        for expected in valid
            bytes = collect(codeunits(expected))
            @test decode(bytes) == expected
            @test decode(bytes; invalid=:replace) == expected
            for split_at = 0:length(bytes)
                decoder = Decoder()
                prefix = feed!(decoder, bytes[1:split_at])
                @test length(decoder._pending) <= 3
                @test prefix * feed!(decoder, bytes[(split_at+1):end]; final=true) ==
                      expected
            end
        end

        # Unicode 17, section 3.9.6: replace each maximal subpart once.
        malformed = [
            (UInt8[0x80], "�"),
            (UInt8[0xc0, 0xaf], "��"),
            (UInt8[0xe0, 0x80, 0xbf], "���"),
            (UInt8[0xed, 0xa0, 0x80], "���"),
            (UInt8[0xf4, 0x91, 0x92, 0x93], "����"),
            (UInt8[0xff], "�"),
            (UInt8[0xc2, 0x41, 0x42], "�AB"),
            (UInt8[0xe1, 0x80, 0x41], "�A"),
            (UInt8[0xf0, 0x90, 0x80, 0x41], "�A"),
            (UInt8[0xc2], "�"),
            (UInt8[0xe1, 0x80], "�"),
            (UInt8[0xf0, 0x90, 0x80], "�"),
            (UInt8[0xe1, 0x80, 0xe2, 0xf0, 0x91, 0x92, 0xf1, 0xbf, 0x41], "����A"),
        ]
        for (bad, expected) in malformed
            @test_throws InvalidUTF8 decode(bad)
            @test decode(bad; invalid=:replace) == expected
            bytes = vcat(codeunits("ok"), bad)
            for split_at = 0:length(bytes)
                decoder = Decoder(; invalid=:replace)
                prefix = feed!(decoder, bytes[1:split_at])
                @test length(decoder._pending) <= 3
                @test prefix * feed!(decoder, bytes[(split_at+1):end]; final=true) ==
                      "ok" * expected

                strict = Decoder()
                failure = try
                    feed!(strict, bytes[1:split_at])
                    feed!(strict, bytes[(split_at+1):end]; final=true)
                catch error
                    error
                end
                @test failure isa InvalidUTF8
                failure isa InvalidUTF8 && @test failure.offset == 3
                @test_throws Base.InvalidStateException feed!(strict, UInt8[])
            end
        end

        source = collect(codeunits("owned \r\n"))
        decoded = decode(source)
        fill!(source, 0xff)
        @test decoded == "owned \r\n"
        decoder = Decoder()
        incomplete = UInt8[0xf0, 0x90, 0x8c]
        @test feed!(decoder, incomplete) == ""
        fill!(incomplete, 0xff)
        @test feed!(decoder, UInt8[0x82]; final=true) == "𐌂"
        @test isempty(decoder._pending)
        @test_throws Base.InvalidStateException feed!(decoder, UInt8[])
        @test_throws ArgumentError Decoder(; invalid=:ignore)
        @test_throws ArgumentError decode(UInt8[]; invalid=:ignore)

        streamed = Decoder()
        pieces = String[]
        for byte in codeunits("A¢€𐍈\r\n")
            push!(pieces, feed!(streamed, UInt8[byte]))
            @test feed!(streamed, UInt8[]) == ""
        end
        push!(pieces, feed!(streamed, UInt8[]; final=true))
        @test join(pieces) == "A¢€𐍈\r\n"

        truncated = Decoder()
        @test feed!(truncated, UInt8[0x41, 0xe1, 0x80]) == "A"
        failure = try
            feed!(truncated, UInt8[]; final=true)
        catch error
            error
        end
        @test failure isa InvalidUTF8
        if failure isa InvalidUTF8
            @test failure.offset == 2
            @test failure.reason == :incomplete_sequence
            @test occursin("byte 2", sprint(showerror, failure))
        end
        @test_throws Base.InvalidStateException feed!(truncated, UInt8[])
    end
end
