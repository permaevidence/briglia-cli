# Conversation snapshots

Briglia preserves the available main conversation before manual pruning, automatic pruning, mid-turn pruning, and chunk archiving that would discard tool rounds, readable reasoning or other detail. Searchable text snapshots live in the data root's `prune-archives` folder. Filenames include UTC date, time to the second, and a unique ID.

The active pruning summary carries a small file reference. Ordinary conversation chunks keep visible messages and typed references; pruning-summary prose and tool results remain in the snapshot, not the chunk. Existing filesystem tools can inspect these files. No model-facing tool is added.

After successful maintenance Briglia retains the latest 300 snapshots across these triggers. This is a count limit, not a byte limit. `/status` and `briglia doctor` show the count and disk usage. References may outlive expired files. Snapshots capture the available context at that event, including nearby messages; they cannot recover material lost before installation. Attachment and spill paths are references and do not pin the original files. Opaque encrypted reasoning and authentication/replay metadata are excluded.

A failed snapshot save leaves detailed history intact. Free disk space or repair the reported permissions and retry. The direct-user command `/prune nosnapshot` skips snapshot creation for that one prune, reports the resulting loss, and still requires the smaller conversation save to succeed. It does not turn off protection for future operations. A completely full or unwritable disk may still require repair.

Full **and lite** Mind backups include snapshots and portable typed references. Lite backups can therefore be substantial. Import replaces the snapshot collection; importing an older backup without snapshots clears destination snapshots. Current CLI transfers preserve this memory, but older CLI versions and Ada.app may ignore the folder and lose it on re-export. Ada.app integration and independent subagent-session compaction are separate work.

This is a recoverable snapshot history, not a complete provider-request log. Existing legacy startup cleanup of old compact tool-log messages remains a compatibility path outside the four snapshot triggers.
