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

Code blocks are paste-and-run units:

- Put one command in each block. An explicit `&&`, `;`, or `\` chain counts
  as one command.
- Put explanations outside the block.
- Use `console` fences with a `$ ` prompt for shell commands.
- Split long commands with `\`, with one flag per continuation line.

## Comments and API documentation

Document what callers can rely on: defaults, ownership, mutation, ordering,
concurrency, errors, and resource cleanup. Keep implementation details out
unless they affect that contract.

Keep source comments that explain a constraint, invariant, failure mode, or
non-obvious intent. Prefer one or two direct lines. Delete narration of the
next lines, restated names or types, speculative requirements, and history
already held by Git. Preserve directives and other text interpreted by
tooling, along with explanations of protocol or platform workarounds.

## Julia API docstrings and links

Follow Julia's [documentation conventions][julia-docs] and Documenter's
[cross-reference syntax][documenter-links]. Write the contract next to its
declaration so REPL help, the native manual, and the shared site use the same
source. Generated HTML and API JSON are outputs, not places to repair prose.

Start a docstring with an indented Julia signature and a short description
of the result. Keep keyword defaults, varargs, type constraints, and dispatch
signatures faithful to the implementation. Do not invent a type annotation
for an untyped keyword. Explain accepted values in prose when the signature
does not express them.

For several nontrivial arguments, use `# Arguments` and one bullet beginning
with a backticked argument, such as `env=ENV`, followed by a colon and its
description. `# Keyword arguments` can separate keyword arguments when useful.
Explain what each input controls, its default behavior, precedence over other
inputs, validation, and relevant errors. A name and default alone do not
document a parameter. Simple functions can explain arguments in their main
description without repeating them in a list.

Keep method-specific behavior with the method it describes. Overloads may
accept the same argument name with different meanings. Document ownership,
I/O, mutation, cancellation, and whether success means dispatch or completion
where these distinctions affect the caller. Source links must identify the
actual declaration and revision; retain separate method links when they lead
to distinct implementations.

Use backticks for Julia identifiers, literals, environment variables, and
types. Link related documented objects with Documenter syntax, for example
``[`Server`](@ref)``, in docstrings. Qualify ambiguous names. Use a short See also
paragraph or section for related operations. Built-in types should link to
their official Julia documentation where the publishing system supports it.

An argument name is not a global Julia docstring binding. Do not invent
`@param` tags or assume `@ref env` can resolve a local keyword. Use Documenter
named anchors for explicit manual sections. The shared site supplies
namespaced parameter permalinks, such as
`LibTmux.from_env.parameter.env`; verify the actual rendered target before
linking to it. Preserve distinct method anchors and existing parameter IDs.

Put examples in an Examples section. Use `jldoctest` when its input and
expected output can be checked; otherwise keep a complete runnable example
and execute it with the documented setup. Check native help, extraction,
rendered descriptions, parameter fragments, and cross-reference targets when
changing this documentation. See [CONTRIBUTING.md](CONTRIBUTING.md) for the
native exporter and manual checks.

[julia-docs]: https://docs.julialang.org/en/v1/manual/documentation/#Writing-Documentation
[documenter-links]: https://documenter.juliadocs.org/stable/man/syntax/#@ref-links-and-@id-anchors

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
