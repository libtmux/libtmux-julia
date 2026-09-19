# SDK adapter contract

The private adapter admits exactly ModelContextProtocol 0.7.0, pinned in
[Project.toml](../Project.toml). Its stock server loop serializes ordinary tool
waits and replaces the global logger, so this package uses a private adapter
around its parser, registration, handlers, and serialization.

The adapter implements these contracts:

- Normalize the pinned SDK's nested `JSON3.Object` values to string-keyed
  dictionaries before tool handlers. Do not accept symbol keys in ordinary
  caller dictionaries or weaken wire validation.
- Freeze registration before serving. Use the SDK's pure server constructor;
  do not start its task-notification dispatcher.
- Keep a fixed worker pool, bounded request ledger, and one bounded writer.
  The reader handles cancellation and discovery while tools wait. Queue
  overflow terminates the connection instead of growing tasks or blocking
  cancellation admission.
- Clone legacy SDK state at request admission. Serialize state-changing
  protocol operations in the reader; refuse repeated initialization while
  work is pending. Support modern 2026-07-28 and legacy 2025-11-25 only.
- Retain request identity until its worker and queued response retire. Reject
  duplicate active IDs without replacing the original request. String and
  integer IDs are distinct; Boolean and floating-point IDs are invalid. A
  separate reply ledger retains discovery and other synchronous request IDs
  until their writes complete without consuming ordinary tool slots.
- Check cancellation before committing any response, progress or log to the
  writer. Do not hold the request lock during I/O. A write already committed
  before cancellation cannot be rolled back.
- On EOF or transport failure, cancel core work, close owned transport I/O,
  join workers and writer, and preserve cleanup failures. Close the transport
  once. After closure, EOF and closed-channel exceptions are expected I/O
  interruptions; unrelated write failures remain errors. Original and cleanup
  errors remain available through `CompositeException`. Arbitrary borrowed
  streams cannot promise interruptible writes without an ownership contract.
- Scope logging with `with_logger`. Keep stdout protocol-only. Filter SDK
  discovery to the supported profiles and capabilities; tasks, resource
  subscriptions and remote HTTP remain unadvertised and unrouted.

The default limits are four workers, 16 admitted ordinary requests, 40 queued
outbound messages, 2 MiB per inbound JSON message, and 8 MiB of queued outbound
bytes. One committed write can retain another message of up to the outbound
byte limit. Ordinary admission cannot fill the work channel beyond its fixed
capacity. The reply ledger is bounded by the output queue plus one active
write and the reader's current response. JSON admission rejects duplicate keys,
invalid UTF-8, nesting deeper than 64, and more than 16,384 lexical tokens.

Progress uses the same bounded writer as responses. The SDK catches errors
from `send_progress`, so the transport wrapper closes the connection before
propagating queue overflow. A cancelled request's queued progress and final
response are suppressed at the writer; an already committed write can finish.
Tool handlers must cooperate with the core cancellation token or the adapter's
cancellation event. The adapter cannot forcibly retire arbitrary Julia code
that ignores cancellation or detached tasks created by a handler.

[Adapter tests](../test/adapter.jl) exercise blocked writes, concurrent
cancellation and discovery, legacy initialization and modern discovery,
separate request state, duplicate IDs, progress suppression, queue byte and
item limits, malformed input, and original-plus-cleanup errors. The controlled
transports use events and owned channel closure. They do not replace external
stdio or real-tmux application checks.

The owned stdio transport unwraps `IOContext` before interrupting libuv pipes;
Julia's default stdout may use that wrapper. The
[external stopped-reader regression](../test/stdio_backpressure.py) consumes
exactly one byte of a large response, stops reading, then closes stdin. It
requires process retirement within 900 ms and verifies that the response did
not drain. Framing tests separately cover wrapped input and output endpoints.

The integration uses internal SDK names. Pinning is a compatibility decision,
not a claim that those names are supported upstream APIs. Upgrade admission
must rerun external stdio, cancellation, slow-writer, state-race and cleanup
checks before changing the dependency constraint.

The consumer package precompiles inert catalog, argument validation, protocol
parsing/serialization, error and CLI option paths with PrecompileTools. The
workload opens no endpoints, files, processes or streams. It does not warm a
running application with fake requests, and it does not remove the need to
measure normal-compiler startup and first-use latency.
