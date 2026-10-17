using Test
using LibTmuxWorkspace
import LibTmux
import JSON

# A real daemon below the floor behind a current client: `LIBTMUX_TEST_TMUX`
# names the old release and `LIBTMUX_TEST_CLIENT_TMUX` the client. The reject
# lanes set `LIBTMUX_TEST_REQUIRE_OLD_DAEMON` so that missing builds fail the
# run instead of skipping this file.
@testset "the workspace CLI refuses a real old daemon" begin
    old = get(ENV, "LIBTMUX_TEST_TMUX", "")
    client = get(ENV, "LIBTMUX_TEST_CLIENT_TMUX", "")
    require = get(ENV, "LIBTMUX_TEST_REQUIRE_OLD_DAEMON", "") == "1"
    require && @test !isempty(old) && !isempty(client)
    if isempty(old) || isempty(client)
        @info "no old tmux and current client selected"
    else
        release = last(split(readchomp(`$old -V`)))
        @test !LibTmux._version_at_least(release, LibTmux.MINIMUM_TMUX_VERSION)
        mktempdir(; prefix="ltj-ws-old-") do directory
            socket = joinpath(directory, "s")
            path = joinpath(directory, "workspace.json")
            write(path, """{"session_name":"refused","windows":[{"window_name":"w"}]}""")
            @test success(`$old -S $socket -f /dev/null new-session -d -s old`)
            sessions() = readchomp(
                ignorestatus(`$old -S $socket list-sessions -F '#{session_name}'`),
            )
            try
                for command in (["load", path], ["freeze", "old"]),
                    mode in ("human", "json", "ndjson")

                    out, err = IOBuffer(), IOBuffer()
                    code = LibTmuxWorkspace.main(
                        [
                            command...,
                            "--socket",
                            socket,
                            "--tmux",
                            client,
                            "--output",
                            mode,
                        ];
                        out,
                        err,
                    )
                    text, stdout = String(take!(err)), String(take!(out))
                    @test code == 3
                    @test occursin("Upgrade tmux", text)
                    @test !occursin(r"workspace application|retained|partial|step \d", text)
                    # tmux 3.1 and older answer in terms of the server; later
                    # releases below the floor are named.
                    if LibTmux._version_at_least(release, "3.2")
                        @test occursin("\"$release\" is unsupported", text)
                    else
                        @test occursin("the server is tmux 3.1 or older", text)
                    end
                    if mode != "human"
                        payload = JSON.parse(last(split(chomp(stdout), '\n')))
                        @test payload["error"]["code"] == "tmux_unsupported"
                        @test !haskey(payload, "result")
                    end
                end
                @test sessions() == "old"
            finally
                run(pipeline(ignorestatus(`$old -S $socket kill-server`); stderr=devnull))
            end
        end
    end
end
