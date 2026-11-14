# Install from source

The packages are unregistered. Install the `v0.1.1` tag in the Julia project
that will use them; `Manifest.toml` records the revision. The MCP and workspace
companions are experimental.

## Core

From the consumer project directory:

```console
$ julia \
    --startup-file=no \
    -e 'using Pkg
        Pkg.activate(".")
        repo = "https://github.com/libtmux/libtmux-julia.git"
        revision = "v0.1.1"
        Pkg.add(Pkg.PackageSpec(url=repo, rev=revision))'
```

Have `tmux` on `PATH`. It needs Julia 1.13.1 or newer and tmux 3.3a or newer.
An older or unreadable tmux is refused before any effect;
[Compatibility](compatibility.md) lists what needs a newer one.

## MCP application

Add the core and MCP adapter together. Both specifications name the same revision:

```console
$ julia \
    --startup-file=no \
    -e 'using Pkg
        Pkg.activate(".")
        repo = "https://github.com/libtmux/libtmux-julia.git"
        revision = "v0.1.1"
        Pkg.add([
            Pkg.PackageSpec(url=repo, rev=revision),
            Pkg.PackageSpec(
                url=repo, rev=revision, subdir="packages/LibTmuxMCP",
            ),
        ])'
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

[Connect an MCP client](mcp.md) explains targets, policy and how the launcher
chooses a tmux server.

## Workspace loader

Add the core and workspace adapter together:

```console
$ julia \
    --startup-file=no \
    -e 'using Pkg
        Pkg.activate(".")
        repo = "https://github.com/libtmux/libtmux-julia.git"
        revision = "v0.1.1"
        Pkg.add([
            Pkg.PackageSpec(url=repo, rev=revision),
            Pkg.PackageSpec(
                url=repo, rev=revision, subdir="packages/LibTmuxWorkspace",
            ),
        ])'
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

The packages are not in the General registry.
