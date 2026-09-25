# Command reference

| Command | What it does |
|---|---|
| `rewind <cmd...>` | The change gate. Snapshot → run → health-check → commit or revert. Exits 1 on revert. |
| `rewind trial --for <dur> <cmd...>` | Apply now, auto-revert after `<dur>` unless confirmed. `<dur>` is any systemd time string (`20s`, `5m`, `1h`). Defaults to `5m` if `--for` is omitted. |
| `rewind confirm` | Cancels the pending trial's revert timer and commits it as the new baseline. |
| `rewind commit` | Accepts the current system state as the new verified-good baseline. |
| `rewind status` | The baseline items, each `[ok]` or `[!!]` with the reason. Plus daemon state, last-verified timestamp and pending trial. |
| `rewind check [id]` | Silent pass/fail against a snapshot. Exit 0 = matches. Defaults to `baseline`. |
| `rewind snapshot [id]` | Capture current state under that id. Defaults to `baseline`. |
| `rewind restore [id]` | Restore a snapshot, then verify it took. Defaults to `baseline`. Your manual override. |
| `rewind log [n]` | The unified timeline, last `n` entries (default 30). |
| `rewind why [tx-id]` | Full story for a transaction: command output, service journal, verdict, items covered. Defaults to the most recent. |
| `rewind _drift` | Internal: what the drift timer calls. |
| `rewind _expire <id>` | Internal: what the trial timer calls. |
