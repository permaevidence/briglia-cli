# Tool stage markers (stall diagnostics)

Briglia records the internal stages of every tool call in an append-only
log, so a tool call that stops making progress can be traced to the step
that never finished.

**Where:** `~/.local/share/briglia/logs/stage-markers.log`
(`$XDG_DATA_HOME/briglia/logs/` when set). Owner-only (0600). Rotated at
8 MB to `stage-markers.log.1`. Removed by `/deleteuserdata` with the other
logs.

**What:** one JSON line per record: call id, tool name, stage (for example
`git.checkpoint`, `git.wait_exit`, `git.drain_stdout_barrier`, `fs.write`,
`fs.files_ledger_record`, `lsp.diagnostics`, `mcp.initialize`), enter or
exit, wall-clock and monotonic time, elapsed milliseconds and outcome
(`ok`, `error`, `cancelled`). Never file contents, command text or
secrets; paths appear as basenames only.

**Stall reports:** a stage open longer than 120 s gets one
`stall_suspected` record listing every open stage and, on Linux, what each
thread is waiting on. The complete report is printed to stderr
(`[StageMarkers] STALL REPORT {…}`) by the watchdog itself, so it arrives
even when writing the log file is what hangs, and is also added to the log.
The report changes nothing: the tool call is not cancelled, failed or
retried.

**Reading it:**

    briglia __stage-markers              # latest 40 records
    briglia __stage-markers --unclosed   # stages entered but never finished
    briglia doctor                       # shows the path and size

The reader starts with an `Integrity:` line. `LOSS DETECTED` means some
records never reached the file (sequence gaps, a truncated line, or records
the writer itself reported as unwritten); see "Write failures" below.

**Settings (environment):**

| Variable | Effect |
| --- | --- |
| `BRIGLIA_STAGE_MARKERS=0` | turn the markers off |
| `BRIGLIA_STAGE_MARKERS_PATH=/abs/file` | write elsewhere (for example container-local storage when the data directory is a slow mounted volume). Missing directories on that path are created owner-only; directories that already exist keep their permissions. The log file is 0600. |
| `BRIGLIA_STAGE_MARKERS_STDERR=1` | also print every record to stderr |
| `BRIGLIA_STALL_REPORT_SECONDS=120` | stall-report threshold |

Writing is done by a background thread, one `write(2)` per record and no
fsync, so the tool path never waits for the disk. A record already written
survives a crash or `kill -9`; if the log's volume is slow or hangs, only
the background writer waits.

**Write failures:** every write is checked. If records cannot be written
(disk full, file-size limit, I/O error), Briglia prints one notice to
stderr (then at most one a minute), copies the first 50 unwritten records
to stderr as `[StageMarkers-unwritten] {…}`, and the next record that is
written carries `write_failed_before` with the number lost. A record cut
short is closed off with a newline so later records still parse. Nothing
is retried and the tool path never waits.
