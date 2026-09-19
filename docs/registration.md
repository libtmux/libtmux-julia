# Package registration

The suite contains three independent Julia packages in one repository.
All use MIT and version `0.1.0` for the first unreleased implementation.
Their package identities are fixed:

| Package | Package directory | UUID |
| --- | --- | --- |
| LibTmux | Repository root | `1a5dcb9e-7968-44df-ad70-bf0a17628f09` |
| LibTmuxMCP | `packages/LibTmuxMCP` | `6ec2004f-18ba-4da6-9e55-6cdc607d109e` |
| LibTmuxWorkspace | `packages/LibTmuxWorkspace` | `dc7c1d2a-fec3-4b55-92f0-7133c728c990` |

Each directory contains its own Project.toml, LICENSE, README, source, tests
and changelog. Consumers depend on the public core UUID and compatibility
range. Their project files do not depend on sibling development paths.
Documentation and benchmark environments remain separate from runtime
dependencies.

Before registration, close the required compatibility, external installation,
example, benchmark and DX gates. Retain the exact source revision, dependency
resolution, raw results and package-tree hashes. A green focused check or a
local resolver constraint is not a release-support claim.

Register the core first so the consumers' LibTmux dependency can resolve from
the registry. JuliaRegistrator supports a `subdir` argument for the two
consumer packages; its official documentation describes registration triggers
and the distinction between registration and Git tags/releases.
[Registrator documentation](https://github.com/JuliaRegistries/Registrator.jl#registering-a-package-in-a-subdirectory).

The intended consumer directories are `packages/LibTmuxMCP` and
`packages/LibTmuxWorkspace`. Use those package roots when reviewing registry
metadata and generated release tags. Do not register the repository root
under a consumer package's identity.

Publication requires a separate maintainer action after the required checks
pass.
