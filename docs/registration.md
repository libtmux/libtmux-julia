# Package registration

The suite contains three independent Julia packages in one repository. All
use MIT and declare the unregistered version `0.1.1-alpha.2`. Their
package identities are fixed:

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

Install the public source from [Install](src/installation.md). A version
declaration does not establish a published tag or registry package. Before
registration, verify the exact candidate's compatibility, isolated installs,
examples and documentation. Retain its source revision, dependency resolution,
results and package-tree hashes. A local registration dry run does not prove
acceptance by General or installation from the public registry.

## Register in General

Use a plain version such as `0.1.0`; Registrator rejects prerelease and build
metadata. Once the candidate is reviewed and available on public `master`:

1. Enable the JuliaRegistrator GitHub app for this repository if needed.
2. Comment `@JuliaRegistrator register` on the exact candidate commit to
   request registration of the root `LibTmux` package.
3. Review the generated General pull request and address its checks. New
   package review normally includes a three-day waiting period. The root
   repository is named `libtmux-julia`, rather than `LibTmux.jl`, so General's
   repository-name guideline requires manual review. Renaming is optional.
4. After the core registration merges, check a fresh project's
   `Pkg.add("LibTmux")`, import and real-tmux example.
5. Register the companions when wanted, using separate commit comments:
   `@JuliaRegistrator register subdir=packages/LibTmuxMCP` and
   `@JuliaRegistrator register subdir=packages/LibTmuxWorkspace`. Each depends
   on the registered core. Verify their installed launchers afterward.

See the [Registrator instructions][registrator] and
[General's automatic-merge guidelines][guidelines]. Registry publication
requires these separate maintainer actions; a dry run does not send them.

The intended consumer directories are `packages/LibTmuxMCP` and
`packages/LibTmuxWorkspace`. Use those package roots when reviewing registry
metadata and generated release tags. Do not register the repository root
under a consumer package's identity.

## Optional source tags

General registration does not require a Git tag, GitHub Release, TagBot or tag
protection. If a maintainer later creates a `v*` source tag, the `Julia`
workflow checks tag metadata, runs the product matrix and installs the
resolved commit into a new Julia depot. It records manifest and package-tree
evidence; it does not publish a registry package or GitHub Release. A tag also
triggers documentation publication, so it is outside a local dry run.

[registrator]: https://github.com/JuliaRegistries/Registrator.jl
[guidelines]: https://juliaregistries.github.io/RegistryCI.jl/stable/guidelines/
