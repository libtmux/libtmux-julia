# Writing

This guide governs documentation, user-facing text, comments, and commit
messages. See [CONTRIBUTING.md](CONTRIBUTING.md) for the contribution workflow.

## Voice

Lead with the conclusion or observable behavior. Use active voice, present
tense, concrete nouns, and short sentences. Assume no shared conversation
history; explain referenced tickets and decisions rather than relying on
their identifiers.

Describe current behavior. Keep implementation deliberation and branch
history in commit messages. Avoid filler, marketing claims, emojis, and tool
signatures. Support performance claims with measurements and reproduction
conditions. Do not describe planned capabilities as available features.

## Structure and examples

Explain the reader's task before APIs or flags. State prerequisites and
defaults early. Use prose for explanations, lists for steps or parallel
facts, and tables for comparisons. Use descriptive sentence-case headings
and keep identifiers in backticks.

Keep examples runnable with explicit prerequisites. Verify commands against
the current source. State what passed, failed, or was skipped.

## Markdown

Use CommonMark. Wrap repository prose at 80 columns, except tables and long
links. Do not hard-wrap GitHub issue or pull request paragraphs. Put blank
lines around headings and lists. Keep published text free of personal
information and local absolute paths.

### Code blocks

Code blocks are paste-and-run units:

- Put one command in each block. An explicit `&&`, `;`, or `\` chain counts
  as one command.
- Put explanations outside the block.
- Use `console` fences with a `$ ` prompt for shell commands.
- Split long commands with `\`, with one flag per continuation line.

## Examples

<!-- shared:examples -->

An example is code written for a reader: a program under `examples/`, code in
a doc comment or docstring, and every fenced block in a README or docs page.
Shell blocks also follow [Code blocks](#code-blocks).

The text between the shared markers is the same in every libtmux port.
Change it in all of them together.

### Width

- **Examples stay within 80 columns.** They render in fixed-width boxes that
  scroll sideways, and 80 columns fits a libtmux.org code block in a
  laptop-width window. Comments inside examples wrap at 80 too.
- **The width check enforces it.** It reads the tracked files that
  `.github/example-width.toml` names and fails on a wider line. It measures
  the whole source line, so code in a doc comment counts its indent and
  comment marker. It skips output (a fence tagged `text`, and what a
  `console` block prints), hidden setup lines, and a line that is only a URL;
  an untagged fence counts as code.
- **A line that must stay wider is listed there with its reason.** An entry
  that no longer matches a line fails the check, so no stale entry stays.
- **The formatter's width is the hard limit for all other source.** Example
  directories set their formatter to 80 where the formatter takes a width.

### Reaching 80

- **Change the code, not the line breaks.** A formatter rejoins any line that
  fits its width. Name a sub-expression, use a short example name, hide setup
  the reader does not need, or print less.
- **Break at the outermost level when a break is still needed:** after an
  opening parenthesis with one argument per line, one call per line in a
  chain, one field per line in a literal.
- **Put a comment on its own line above the code it explains.** Never trail
  one after code in an example, unless the repository's example runner reads
  it there, as with an assertion marker.
- **Break a long string at a word boundary,** never inside a tmux format
  (`#{...}`) or an escape sequence; the joined text stays the same.
- **Continue a long command in a `console` block the way its shell does:**
  `\` after a `$ ` prompt, a backtick after `PS> `, one flag per continuation
  line.

### What never breaks

- **Output a test compares.** Wrapping it changes what the test expects.
- **A block copied from a source file.** Fix the width in the source and run
  the sync command; never edit the copy.
- **Marker lines and URLs,** which tools and readers take whole.

<!-- /shared:examples -->

### In this repository

- **Hard limit:** JuliaFormatter, through `format_margin` in
  `dev/check-quality.jl`: 80 under `examples/`, a wider margin elsewhere.
  Keep that margin at 80.
  `dev/check-matrix.py` pins the version. The width check is
  `python3 dev/check_example_width.py`.
- **Not formatted:** Markdown fences and docstring fences, because
  `format_docstrings=false` and the formatter never reads Markdown; hold both
  to the width by hand.
- **Runs, compiles, exempt:** `docs/example-inventory.md`, not the fence tag,
  decides how a block runs: a `jldoctest` fence is a pure doctest Documenter
  runs, a `julia` fence runs against an owned server, and an `@eval` fence
  reads a program under `examples/`. A line over the width is exempt only
  through an `[[allow]]` entry with a reason.
- **Compared output and copied blocks:** never wrap doctest output. A fence
  that reads a program has no copy to edit; change the program. Editing any
  other fence changes its SHA-256 in `DOC_SNIPPETS`; update the fingerprint,
  then sync with
  `julia --startup-file=no --compile=min -O0 dev/check-doc-examples.jl write`.

Bad, over 80:

```julia
selected = filter(PaneWhere(active=true, window=WindowWhere(name="api")), panes(snap))
```

Good, a named value instead of a line break:

```julia
in_api = WindowWhere(name="api")
selected = filter(PaneWhere(active=true, window=in_api), panes(snap))
```

## Comments and API documentation

Document what callers can rely on: defaults, ownership, mutation, ordering,
concurrency, errors, and resource cleanup. Keep implementation details out
unless they affect that contract.

Keep source comments that explain a constraint, invariant, failure mode, or
non-obvious intent. Prefer one or two direct lines. Delete narration of the
next lines, restated names or types, speculative requirements, and history
already held by Git. Preserve directives and other text interpreted by
tooling, along with explanations of protocol or platform workarounds.

## Commit messages

Use `Scope(type[detail]): Concise description`. The detail qualifier is
optional. Use an imperative, capitalized description without a trailing
period. Keep subjects within 50 characters and body lines within 72, except
indivisible URLs or identifiers.

Use `docs` for documentation, `chore` for configuration, and `rules[AGENTS]`
or `rules[claude]` under the `Ai` scope for agent entry points. Use `feat`,
`fix`, `refactor`, `test`, `style`, or `ci` when they describe the change.

A small, self-explanatory change can use a subject alone. For a change that
needs a body, explain the reason in a `why:` paragraph, then list the
concrete changes under `what:`. Separate those sections with a blank line.
Use a heredoc or a message file to preserve newlines.

Keep each commit focused on one logical change. Do not add emojis, tool
signatures, or PR numbers to ordinary commits. A merge message's PR number
must identify the PR that produced the merge. Create or push release tags
only when the maintainer requests it.

## Review descriptions

Open with the concrete problem and resulting behavior. Describe the final
change and relevant verification, including failures or skipped checks.
Include implementation details only when they help assess correctness or a
tradeoff. A reviewer should not need the conversation to understand the work.
