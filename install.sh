#!/usr/bin/env bash
# Install rewind onto a RHEL-family host (tested on Rocky Linux 9).
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
cd "$(dirname "$0")"

install -Dm755 bin/rewind            /usr/local/bin/rewind
install -Dm644 lib/lib.sh            /usr/local/lib/rewind/lib.sh
install -Dm644 lib/drift.sh          /usr/local/lib/rewind/drift.sh
install -Dm644 lib/ui.sh             /usr/local/lib/rewind/ui.sh
install -Dm644 systemd/rewind-drift.service /etc/systemd/system/rewind-drift.service
install -Dm644 systemd/rewind-drift.timer   /etc/systemd/system/rewind-drift.timer
mkdir -p /var/lib/rewind
if [[ -f /etc/rewind/baseline ]]; then
  echo "keeping existing /etc/rewind/baseline"
else
  install -Dm644 etc/baseline /etc/rewind/baseline
fi

systemctl daemon-reload
rewind snapshot                      # capture the current state as the verified-good baseline
systemctl enable --now rewind-drift.timer
rewind status
