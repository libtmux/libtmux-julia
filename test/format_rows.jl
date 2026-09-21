@testset "finite tmux format rows" begin
    @test isdefined(LibTmux, :_format_template)
    @test isdefined(LibTmux, :_decode_format_rows)
    if isdefined(LibTmux, :_format_template) && isdefined(LibTmux, :_decode_format_rows)
        template = LibTmux._format_template
        decode = LibTmux._decode_format_rows
        @test isempty(decode(UInt8[], 2))
        @test decode(codeunits("\t\n\t\n"), 2) == [["", ""], ["", ""]]
        @test decode(codeunits("a\tb\n"), 2) == [["a", "b"]]
        @test decode(codeunits("tabs\\there\\nlines\tliteral\\\\n\n"), 2) ==
              [["tabs\there\nlines", "literal\\n"]]
        @test decode(codeunits("π😀\t#{raw}\\\\end\r  \n"), 2) ==
              [["π😀", "#{raw}\\end\r  "]]
        @test decode(@view(codeunits("!a\tb\n!")[2:5]), 2) == [["a", "b"]]
        @test decode(codeunits("\\n\n"), 1) == [["\n"]]
        @test decode(codeunits("\\\\\n"), 1) == [["\\"]]
        for encoded in ("\\12\n", "\\400\n", "\\0q0\n")
            @test_throws ArgumentError decode(codeunits(encoded), 1)
        end

        for value in
            ("a\tb", "a\t", "\\", "a\tb\\\n", "\\x\n", "\\\t\n", "a\tb\tc\n", "a\n")
            @test_throws ArgumentError decode(codeunits(value), 2)
        end
        @test_throws ArgumentError decode(UInt8[0xff, 0x0a], 1)
        @test_throws ArgumentError decode(UInt8[0xc3, 0x0a], 1)
        @test_throws ArgumentError decode(UInt8[], 0)

        prefix = raw"#{s|\\|\\\\|;s|[$]|\\d|;s|" * "\t" * raw"|\\t|;s|" * "\n" * raw"|\\n|:"
        @test template(["pane_id", "pane_title"]) ==
              prefix * "pane_id}\t" * prefix * "pane_title}"
        @test template(["x", "x"]) == prefix * "x}\t" * prefix * "x}"
        for fields in (
            String[],
            ["Pane_id"],
            ["pane-id"],
            ["pane_id\n"],
            ["pane_id\t"],
            ["1pane"],
            ["@option"],
            ["pane_id}"],
            ["#{pane_id}"],
            ["pane_id;run-shell"],
            ["π"],
        )
            @test_throws ArgumentError template(fields)
        end
    end
end

@testset "format update values decode locally" begin
    identity =
        ServerIdentity(socket_path="/tmp/libtmux-julia-uncontacted/s", generation="sample")
    cursor = ObservationCursor(identity, nothing, "epoch", :format, UInt64(1))
    bytes = collect(codeunits(raw"tab\tline\nliteral\\n λ"))
    update = FormatUpdate(
        "window_name",
        bytes,
        SessionRef(identity, "\$0"),
        nothing,
        nothing,
        nothing,
        cursor,
    )
    @test format_value(update) == "tab\tline\nliteral\\n λ"
    @test update.bytes == bytes
    bad = FormatUpdate(
        "window_name",
        UInt8[0x5c],
        update.session,
        nothing,
        nothing,
        nothing,
        cursor,
    )
    @test_throws ArgumentError format_value(bad)
end
