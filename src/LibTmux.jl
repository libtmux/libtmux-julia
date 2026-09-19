module LibTmux

export Server, from_env
export CancellationToken, cancel!, CommandResult, run_command
export CancellationSubscription, on_cancel, iscancelled
export LibTmuxError, TmuxNotFound, CommandError, RequestCancelled
export DeadlineExceeded, OutputLimitExceeded, ProcessIOError, ProcessSpawnError
export OwnedServer, OwnedServerStartError, OwnedServerCleanupError, open_server, with_server
export ServerIdentity, SessionID, WindowID, PaneID, ClientID
export SessionRef, WindowRef, PaneRef, ClientRef
export Snapshot, SessionSnapshot, WindowSnapshot, PaneSnapshot, ClientSnapshot
export WindowLink, PaneOccurrence, Selection, snapshot, snapshotof
export sessions, windows, panes, clients, windowlinks, paneoccurrences, window, session
export entitykey, occurrencekey, hascoverage, SnapshotCoverageError, InconsistentSnapshot
export UnsupportedCapability
export InvalidUTF8Error, TextDecoder, decode_text, decode!
export new_session, new_window, split_window, select_layout
export select_pane, select_window
export kill_session, kill_window, kill_pane, CrossServerReference, StaleReference
export CreationResponseError, CaptureDecodeError, BufferID, BufferRef
export capture_bytes, capture_pane, send_keys, load_buffer, save_buffer, delete_buffer
export paste_bytes, paste_text
export WindowLinkRef, resize_pane, resize_window, link_window, unlink_window
export move_pane, move_window, swap_pane, swap_window, respawn_pane, respawn_window
export rename_session, rename_window, switch_client, detach_client
export EnvironmentValue, HookCommand, get_option, set_option, unset_option
export get_environment, set_environment, unset_environment, remove_environment
export get_hook, set_hook, unset_hook
export FormatField, FormatObservation, FormatValueError, read_formats
export RawFormat, render_format, FormatHints, format_hints
export ControlConnection, ControlResult, ControlCommandError, ControlConnectionError
export ControlTargetError, ControlCleanupError, open_control, ControlSignal, control_signal
export ControlCaptureCleanupError
export TmuxCommand, OperationResult, BatchResult, GroupResult, run_batch, run_group
export ObservationEvent, NotificationEvent, PaneOutput, FormatUpdate, ObservationLost
export ObservationCursor, ObservationStream, notifications, observe_output, subscribe_format
export observation_cursor, ObservationBaseline, capture_baseline
export format_value
export Criterion,
    Filters, PaneWhere, WindowWhere, SessionWhere, ClientWhere, WindowLinkWhere
export onlymatch, NoMatchError, MultipleMatchesError
export encode_where, decode_where, WireObject, WireCriteriaError, WhereLimits
export read_where_json, write_where_json
export project_rows, RowProjection
export UnsupportedCriterion, encode_typescript_where, decode_typescript_where
export encode_rust_where, decode_rust_where

include("server.jl")
include("process.jl")
include("text.jl")
include("lifecycle.jl")
include("model.jl")
include("format_rows.jl")
include("acquisition.jl")
include("operations.jl")
include("pane_io.jl")
include("topology.jl")
include("configuration.jl")
include("formats.jl")
include("control_protocol.jl")
include("control.jl")
include("batches.jl")
include("observation.jl")
include("control_io.jl")
include("control_operations.jl")
include("control_topology.jl")
include("control_formats.jl")
include("control_configuration.jl")
include("criteria.jl")
include("wire.jl")
include("sibling_wire.jl")
include("projection.jl")
include("precompile.jl")

end
