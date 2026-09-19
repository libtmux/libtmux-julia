# Troubleshooting

| Symptom | Meaning and next step |
| --- | --- |
| tmux cannot start | Check the executable passed to `Server` or `open_server` |
| Socket path too long | Use a shorter temporary directory for owned daemons |
| No match | Check whether the source contains entities or link occurrences |
| Coverage error | Acquire the required field/relation; absence was not established |
| Stale reference | Reacquire intentionally and reconsider whether to repeat the action |
| Invalid capture UTF-8 | Use bytes, or explicitly select text replacement |
| Unknown format returns empty | Empty does not establish unsupported versus absent |
| Control protocol failure | Close the connection; inspect configured hooks/aliases |
| Cleanup error | Inspect retained resource/effect evidence before any new action |

Never reinterpret a missing target as the current pane. Typed format reads
use strict target resolution before expansion. [`RawFormat`](@ref) permits
tmux expressions, including host shell jobs; ordinary field names do not.

For command failures, keep the structured error result. Display methods use
bounded diagnostics. Cancellation and deadlines can carry `sent=true`,
meaning the remote command may already have changed tmux state.
