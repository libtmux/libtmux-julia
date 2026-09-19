@testset "bounded control protocol" begin
    @test isdefined(LibTmux, :_ControlParser)
    @test isdefined(LibTmux, :_encode_control_command)
    if isdefined(LibTmux, :_ControlParser) && isdefined(LibTmux, :_encode_control_command)
        Parser = LibTmux._ControlParser
        Policy = LibTmux._ControlReplyPolicy
        ProtocolError = LibTmux._ControlProtocolError
        feed = LibTmux._control_feed!
        encode = LibTmux._encode_control_command
        admit = LibTmux._admit_control_command
        rows = _ -> Policy(; prefix="ROW\t", diagnostics=true)
        wire = codeunits(
            "%begin 12 500 1\nROW\tα\\nβ\n%pause %3\n" *
            "%output %3 a\\000\\134\\377\n%end 12 500 1\n",
        )
        for cut = 0:length(wire)
            parser = Parser(; frame_policy=rows)
            events = [
                feed(parser, @view(wire[1:cut]));
                feed(parser, @view(wire[(cut+1):end]); final=true)
            ]
            @test length(events) == 3
            @test events[1].name === :pause
            @test events[2].bytes == UInt8[0x61, 0x00, 0x5c, 0xff]
            @test events[3].guard.number == 500
            @test events[3].payload == collect(codeunits("ROW\tα\\nβ\n"))
        end
        parser = Parser()
        events = Any[]
        for byte in codeunits("%begin 1 2 0\n%end 1 2 0\n%begin 1 19 1\n%error 1 19 1\n")
            append!(events, feed(parser, UInt8[byte]))
        end
        append!(events, feed(parser, UInt8[]; final=true))
        @test [(event.guard.flags, event.failed) for event in events] == [(0, false), (1, true)]
        @test_throws InvalidStateException feed(parser, UInt8[])

        output =
            only(feed(Parser(), codeunits("%extended-output %12 98 : \\033[1m\\012\n")))
        @test output.pane == 12
        @test output.age_ms == 98
        @test output.bytes == collect(codeunits("\e[1m\n"))
        @test only(feed(Parser(), UInt8[codeunits("%output %0 "); 0xff; 0x0a])).bytes ==
              [0xff]

        for notification in (
            "%sessions-changed",
            "%window-add @1",
            "%window-pane-changed @1 %2",
            "%session-changed \$0 name with spaces",
            "%session-window-changed \$0 @1",
            "%layout-change @1 abc def *",
            "%paste-buffer-changed owned",
            "%subscription-changed owned \$0 - - - : data",
            "%config-error failure",
            "%client-detached /dev/pts/1",
            "%client-session-changed /dev/pts/1 \$0 name",
            "%window-renamed @1 ",
            "%exit",
        )
            @test only(feed(Parser(), codeunits(notification * "\n"))) isa
                  LibTmux._ControlNotification
        end

        for kind in ("paste-buffer-changed", "paste-buffer-deleted"),
            name in (" leading", "two  spaces", " ")

            record = "%" * kind * " " * name
            event = only(feed(Parser(), codeunits(record * "\n")))
            @test event.bytes == codeunits(record)
        end

        for malformed in (
            "%end 1 2 1\n",
            "%begin -1 2 1\n",
            "%begin 1 2 1 extra\n",
            "%begin 1 2 1\n%end 1 3 1\n",
            "%begin 1 2 1\n%begin 1 3 1\n",
            "%begin 1 2 1\ntext\n",
            "%unknown thing\n",
            "%pause bad\n",
            "%output %0 \\400\n",
            "%output %0 \\00\n",
            "%output %0 \\x00\n",
            "%extended-output %0 nope : data\n",
            "%sessions-changed extra\n",
            "%begin 18446744073709551616 2 1\n",
            "%output %0 raw\r\n",
            "%window-renamed @1\n",
            "%paste-buffer-changed\n",
            "%paste-buffer-deleted \n",
        )
            parser = Parser()
            @test_throws ProtocolError feed(parser, codeunits(malformed))
            @test_throws InvalidStateException feed(parser, UInt8[])
        end
        for truncated in ("%beg", "%begin 1 2 1\n", "%output %0 a")
            @test_throws ProtocolError feed(Parser(), codeunits(truncated); final=true)
        end
        @test_throws ProtocolError feed(Parser(; max_line_bytes=5), codeunits("123456"))
        @test_throws ProtocolError feed(
            Parser(; frame_policy=rows, max_frame_bytes=4),
            codeunits("%begin 1 2 1\nROW\tx\n"),
        )
        @test_throws ProtocolError feed(
            Parser(; max_events=1),
            codeunits("%sessions-changed\n%sessions-changed\n"),
        )
        @test_throws ArgumentError Policy(; prefix="%unsafe")
        @test_throws ArgumentError Policy(; prefix="bad\n")
        @test_throws ArgumentError Parser(; max_events=0)

        diagnostic = _ -> Policy(; diagnostics=true)
        frame = only(
            feed(
                Parser(; frame_policy=diagnostic),
                codeunits("%begin 1 2 1\ncan't find pane: %9\n%error 1 2 1\n"),
            ),
        )
        @test frame.failed
        @test frame.payload == collect(codeunits("can't find pane: %9\n"))
        @test_throws ProtocolError feed(
            Parser(; frame_policy=diagnostic),
            codeunits("%begin 1 2 1\n%unrecognized payload\n"),
        )
        @test_throws ProtocolError feed(
            Parser(; frame_policy=rows),
            codeunits("%begin 1 2 1\nunprefixed row\n%end 1 2 1\n"),
        )
        @test_throws ProtocolError feed(
            Parser(; frame_policy=diagnostic),
            codeunits("%begin 1 2 1\nunexpected output\n%end 1 2 1\n"),
        )

        # A matching forged guard is undecidable; raw capture must fail admission.
        parser = Parser(; frame_policy=diagnostic)
        @test length(feed(parser, codeunits("%begin 1 2 1\n%end 1 2 1\n"))) == 1
        @test_throws ProtocolError feed(parser, codeunits("%end 1 2 1\n"))
        encoded_output = UInt8[codeunits("%output %1 ");]
        for byte = UInt8(0):UInt8(255)
            if byte < 0x20 || byte == 0x5c
                append!(
                    encoded_output,
                    codeunits("\\" * lpad(string(byte; base=8), 3, '0')),
                )
            else
                push!(encoded_output, byte)
            end
        end
        push!(encoded_output, 0x0a)
        @test only(feed(Parser(), encoded_output)).bytes == collect(UInt8(0):UInt8(255))

        @test encode(["send-keys", "", "a'b", ";", "x\ny", "π"]) ==
              "'send-keys' '' 'a'\"'\"'b' ';' 'x'\\012'y' \\317\\200\n"
        @test encode(["display-message", raw"$x #{y} `z` " * "\\"]) ==
              "'display-message' '\$x #{y} `z` \\'\n"
        @test_throws ArgumentError encode(String[])
        @test_throws ArgumentError encode(["", "x"])
        @test_throws ArgumentError encode(["cmd", "\0"])
        @test_throws ArgumentError encode(["cmd", "1234"]; max_argument_bytes=3)
        @test_throws ArgumentError encode(["cmd", "x"]; max_arguments=1)
        @test_throws ArgumentError encode(["cmd"]; max_line_bytes=3)
        @test admit(["kill-pane", "-t", "%1"]) isa LibTmux._ControlReplyPolicy
        @test admit(["delete-buffer", "-b", "owned-safe"]) isa LibTmux._ControlReplyPolicy
        for unsafe in (
            ["capture-pane", "-p", "-t", "%1"],
            ["display-message", "-p", "text"],
            ["run-shell", "echo hi"],
            ["kill-pane", "-t", "%1\n%end 1 2 1"],
            ["kill-pane", "-a"],
            ["kill-pane", "-t", "name"],
            ["delete-buffer", "-b", "bad\rname"],
            ["kill-pane", "-t", "%1", ";"],
        )
            @test_throws ArgumentError admit(unsafe)
        end
    end
end
