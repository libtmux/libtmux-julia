# check-release-tag

Verifies a pushed `v*` tag before a public install and writes the release record
that `dev/check-tag-install.jl` reads.

The `Julia` workflow runs it twice for a release tag: in the planning job, and in
the `tag-install` job before and after the public install, where it must write
the same record both times. It checks that the push event created the tag and did
not delete or force it, that the public remote holds the tag at the workflow's
commit, that the checkout is that commit and clean, that the commit is reachable
from `master`, and that the three package manifests match the tag and carry their
UUIDs. The record names each package and its tree.

```console
$ julia \
    --startup-file=no \
    --project=scripts/check-release-tag \
    scripts/check-release-tag/check-release-tag.jl verify \
    --checkout . \
    --event "$GITHUB_EVENT_PATH" \
    --tag v0.1.1 \
    --commit "$GITHUB_SHA" \
    --ref refs/tags/v0.1.1 \
    --repository libtmux/libtmux-julia \
    --output release.toml
```

The `JSON` package reads the event file; the project in this directory is the only
one that needs it. Prepare it once, then run the tests, which build a fixture
repository, a bare remote and a shallow clone and need no network:

```console
$ julia \
    --startup-file=no \
    --project=scripts/check-release-tag \
    -e 'using Pkg; Pkg.instantiate()'
```

```console
$ julia \
    --startup-file=no \
    --project=scripts/check-release-tag \
    scripts/check-release-tag/tests/runtests.jl
```
