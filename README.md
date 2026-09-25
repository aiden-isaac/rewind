# rewind

**Transactional changes and self-healing configuration for RHEL-family servers.**

🏆 Champion, Red Hat Hackathon 2026.

Every change you make to a server is a gamble: a typo in `httpd.conf`, a firewall rule that locks you out, an SELinux toggle someone forgot to undo. `rewind` wraps changes in a transaction. It snapshots the system, runs your command, health-checks the result, and either commits it as the new known-good baseline or rolls it back automatically. A systemd timer watches for drift between changes and puts the system back.

Pure Bash, no dependencies beyond what ships with Rocky Linux / RHEL 9.

```
$ rewind bash -c 'echo "NotADirective 1" >> /etc/httpd/conf/httpd.conf && systemctl restart httpd'
rewind: TX tx-1788677632 REVERT: exit 1: AH00526: Syntax error on line 361 of /etc/httpd/conf/httpd.conf:
rewind: restore tx-1788677632 OK (verified)
rewind: TX tx-1788677632 REVERTED: back at pre-change state (details: rewind why tx-1788677632)
```

## Features

- **Change gate.** `rewind <cmd>` snapshots, runs, health-checks for up to 10s, then commits or reverts. The command's exit code *and* live health checks both have to pass.
- **Trial changes.** `rewind trial --for 5m <cmd>` applies a risky change (e.g. a firewall rule over SSH) and reverts it automatically unless you `rewind confirm` in time, so you can't lock yourself out.
- **Drift correction.** A systemd timer compares the live system to the baseline every few seconds. After 2 consecutive failed checks (to avoid flapping), it restores the baseline.
- **Change correlation.** If a service starts failing shortly after a change that passed its health check (within 180s by default), and the config files themselves are intact, rewind blames that change and rolls *it* back, instead of restarting the service into the same fault. Example: a `MemoryMax` drop-in that gets httpd OOM-killed under load.
- **Explainability.** `rewind log` shows a single timeline of operator and autonomous actions. `rewind why` shows the full story of a transaction: command output, journal lines for failing services, verdict and which items were covered.
- **SELinux-aware.** Snapshots keep ownership, mode and SELinux context, and restores put all three back.

## What it tracks

The baseline manifest at `/etc/rewind/baseline` lists what rewind protects, one item per line:

```
service:httpd:enabled:running
selinux:mode:enforcing
file:/etc/httpd/conf/httpd.conf:root:root:644:httpd_config_t
dir:/var/www/html:root:root:755:httpd_sys_content_t
firewall:service:http
firewall:service:ssh
health:httpd:curl -sf -m 2 http://localhost/
service:sshd:enabled:running
file:/etc/hosts:root:root:644:net_conf_t
```

| Type | Format | Snapshot / check / restore |
|---|---|---|
| `service` | `service:<name>:<enabled\|disabled>:<running\|stopped>` | enablement, active state and `/etc/systemd/system/<name>.service.d` drop-ins |
| `selinux` | `selinux:mode:<enforcing\|permissive>` | `getenforce` / `setenforce` |
| `file` | `file:<path>:<user>:<group>:<mode>:<selinux_type>` | content hash, ownership, mode, SELinux type |
| `dir` | `dir:<path>:<user>:<group>:<mode>:<selinux_type>` | recursive content hash (tar with xattrs + SELinux labels) |
| `firewall` | `firewall:<service\|port\|...>:<value>` | runtime *and* permanent firewalld config |
| `health` | `health:<name>:<shell command>` | any command; exit 0 = healthy |

After editing the manifest, run `rewind commit` to take a new baseline.

## Install

Requires root on a RHEL 9-family host (Rocky, Alma, RHEL) with systemd, firewalld and SELinux.

```bash
git clone https://github.com/aiden-isaac/rewind.git
cd rewind
sudo ./install.sh
```

The installer copies files into place (keeping any existing `/etc/rewind/baseline`), takes the first baseline snapshot and enables the drift timer. The example baseline assumes `httpd` is installed and serving `http://localhost/`. Edit `/etc/rewind/baseline` to match your host.

## Usage

```bash
rewind status                                   # is the system at baseline?
rewind systemctl restart httpd                  # gated change
rewind trial --for 2m firewall-cmd --remove-service=http
rewind confirm                                  # keep it
rewind log                                      # timeline
rewind why                                      # explain the last transaction
```

See [docs/COMMANDS.md](docs/COMMANDS.md) for every command.

## Demo scenarios

These are the scenarios from the hackathon demo:

```bash
# 1. Bad config: reverted on the spot
rewind bash -c 'echo "NotADirective 1" >> /etc/httpd/conf/httpd.conf && systemctl restart httpd'

# 2. Lockout protection: SSH comes back after 20s with no confirm
rewind trial --for 20s firewall-cmd --remove-service=ssh

# 3. Delayed failure: passes the health check, then OOMs; drift correlation rolls it back
rewind bash -c 'mkdir -p /etc/systemd/system/httpd.service.d && printf "[Service]\nMemoryMax=20M\nMemorySwapMax=0\nOOMPolicy=stop\n" > /etc/systemd/system/httpd.service.d/override.conf && systemctl daemon-reload && systemctl restart httpd'

# 4. Out-of-band tampering: fixed by the drift timer
systemctl stop sshd; echo "1.2.3.4 evil.example" >> /etc/hosts
setenforce 0; chmod 600 /etc/httpd/conf/httpd.conf
```

`scripts/demo-reset.sh` puts the VM back to a clean demo state between runs.

## How it works

```
            ┌──────────── rewind <cmd> ────────────┐
 snapshot ─▶│ run cmd ─▶ exit 0? ─▶ health ok? ─▶ COMMIT (new baseline)
            │               └─ no ──────┴─ no ─▶ REVERT ─▶ restore ─▶ verify
            └──────────────────────────────────────┘

 rewind-drift.timer ─▶ check baseline ─▶ 2 strikes ─▶ recent commit & config intact?
                                                        ├─ yes ─▶ roll back that commit
                                                        └─ no  ─▶ restore baseline
```

- Restores apply config first and services last, then re-run `check` to verify the restore worked.
- Transactions and the drift daemon share a `flock` on `/run/rewind.lock`, so the daemon never "corrects" a change that is still in progress. A pending trial also pauses the daemon.
- The last 20 transaction snapshots are kept under `/var/lib/rewind/`.
- Every event goes to the timeline file and to syslog (`journalctl -t rewind`).

## Layout

| Repo path | Installed to | Purpose |
|---|---|---|
| `bin/rewind` | `/usr/local/bin/rewind` | CLI entry point and command dispatch |
| `lib/lib.sh` | `/usr/local/lib/rewind/lib.sh` | core: `snapshot` / `check` / `restore` per item type |
| `lib/drift.sh` | `/usr/local/lib/rewind/drift.sh` | drift daemon with change correlation |
| `lib/ui.sh` | `/usr/local/lib/rewind/ui.sh` | `status`, `why`, coloured `log`, richer transaction output |
| `etc/baseline` | `/etc/rewind/baseline` | example manifest |
| `systemd/rewind-drift.{service,timer}` | `/etc/systemd/system/` | drift timer (runs every 5s) |
| `scripts/demo-reset.sh` | | resets the demo VM |

`drift.sh` and `ui.sh` are sourced after the functions in `bin/rewind`, so their `cmd_drift`, `cmd_run` and `cmd_log` replace the simpler originals there.

### Tuning

| Variable | Default | Meaning |
|---|---|---|
| `REWIND_STRIKES` | `2` | consecutive failed drift checks before correcting |
| `REWIND_CORRELATE` | `180` | seconds after a commit during which a behavioural failure is blamed on it |
| `REWIND_ROOT` | `/var/lib/rewind` | snapshot and state directory |
| `BASELINE_FILE` | `/etc/rewind/baseline` | manifest path |

## License

[MIT](LICENSE)
