# Upper bound on a wait for an event that is expected to happen. Tests return
# as soon as the event does; the bound only turns a hang into a failure.
const HANG_GUARD = 30.0
