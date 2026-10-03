# Install from source

The packages are unregistered. Install this tested public source revision
in the Julia project that will use them. `Manifest.toml` records the
requested revision and package tree hashes.

## Core

From the consumer project directory:

```console
$ julia \
    --startup-file=no \
    -e 'using Pkg; Pkg.activate("."); Pkg.add(Pkg.PackageSpec(url="https://github.com/libtmux/libtmux-julia.git", rev="9e3776d07798174a3590a728d28029efcbb52780"))'
```

Have `tmux` on `PATH`. Julia 1.10+ and tmux 3.2a+ are the compatibility
targets; [Compatibility](compatibility.md) records the exact tested cells.

## MCP application

Add the core and MCP adapter together. Both specifications name the same revision:

```console
$ julia \
    --startup-file=no \
    -e 'using Pkg; Pkg.activate("."); repo="https://github.com/libtmux/libtmux-julia.git"; revision="9e3776d07798174a3590a728d28029efcbb52780"; Pkg.add([Pkg.PackageSpec(url=repo, rev=revision), Pkg.PackageSpec(url=repo, rev=revision, subdir="packages/LibTmuxMCP")])'
```

Install the local launcher after resolution:

```console
$ julia \
    --startup-file=no \
    --project=. \
    -e 'using LibTmuxMCP; println(install_cli("bin"))'
```

```console
$ bin/libtmux-mcp --help
```

[Connect an MCP client](mcp.md) explains targets, policy and the explicit
socket selector.

## Workspace loader

Add the core and workspace adapter together:

```console
$ julia \
    --startup-file=no \
    -e 'using Pkg; Pkg.activate("."); repo="https://github.com/libtmux/libtmux-julia.git"; revision="9e3776d07798174a3590a728d28029efcbb52780"; Pkg.add([Pkg.PackageSpec(url=repo, rev=revision), Pkg.PackageSpec(url=repo, rev=revision, subdir="packages/LibTmuxWorkspace")])'
```

Install the local launcher after resolution:

```console
$ julia \
    --startup-file=no \
    --project=. \
    -e 'using LibTmuxWorkspace; println(install_cli("bin"))'
```

```console
$ bin/libtmux-workspace --help
```

[Load a workspace](workspaces.md) describes validation, planning, loading and
freezing.

The alpha is not in the General registry. Registry registration is a later
maintainer action.
