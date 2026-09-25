#!/usr/bin/env bash
# rewind core: snapshot() / check() / restore() + shared helpers
set -euo pipefail

REWIND_ROOT="${REWIND_ROOT:-/var/lib/rewind}"
BASELINE_FILE="${BASELINE_FILE:-/etc/rewind/baseline}"
LOCK_FILE="/run/rewind.lock"
TIMELINE="$REWIND_ROOT/timeline"
PENDING="$REWIND_ROOT/pending"
STRIKES_FILE="$REWIND_ROOT/strikes"
REWIND_STRIKES="${REWIND_STRIKES:-2}"
KEEP_TX=20

log() { logger -t rewind -- "$*"; printf 'rewind: %s\n' "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root"

timeline() {  # timeline <kind> <id> <event> <detail>
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date -Is)" "$1" "$2" "$3" "$4" >> "$TIMELINE"
  log "$1 $2 $3: $4"
}

# ---- helpers ---------------------------------------------------------------
own_of()   { stat -c '%U:%G:%a' -- "$1"; }
ctx_of()   { stat -c '%C' -- "$1" | cut -d: -f3; }
hash_of()  { sha256sum -- "$1" | cut -c1-64; }
hash_dir() { ( cd -- "$1" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum ) | sha256sum | cut -c1-64; }

wait_active() {  # wait_active <svc> [seconds]
  local svc=$1 t=${2:-15} i
  for ((i=0; i<t; i++)); do
    systemctl is-active --quiet "$svc" && return 0
    sleep 1
  done
  return 1
}

health_ok() {  # health_ok [tries] — runs only the health: lines, retrying 1s apart
  local tries=${1:-10} i line type name rest ok
  for ((i=0; i<tries; i++)); do
    ok=1
    while IFS= read -r line || [[ -n $line ]]; do
      [[ $line == health:* ]] || continue
      IFS=: read -r type name rest <<<"$line"
      bash -c "$rest" >/dev/null 2>&1 || ok=0
    done < "$BASELINE_FILE"
    [[ $ok -eq 1 ]] && return 0
    sleep 1
  done
  return 1
}

each_item() {  # each_item <fn> <snap_id> — fn <idx> <line> <id> per manifest line
  local fn=$1 id=$2 n=0 rc=0 line
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* ]] && continue
    n=$((n+1))
    "$fn" "$n" "$line" "$id" || rc=1
  done < "$REWIND_ROOT/$id/manifest"
  return $rc
}

# ---- per-item primitives ---------------------------------------------------
snapshot_item() {
  local n=$1 line=$2 id=$3; local d="$REWIND_ROOT/$id/items/$n" type name rest
  IFS=: read -r type name rest <<<"$line"
  mkdir -p "$d"
  case $type in
    service)
      { echo "enabled=$(systemctl is-enabled "$name" 2>/dev/null || true)"
        echo "active=$(systemctl is-active "$name" 2>/dev/null || true)"; } > "$d/meta"
      rm -f "$d/dropins.tar"
      if [[ -d /etc/systemd/system/$name.service.d ]]; then
        tar --selinux -cpf "$d/dropins.tar" -C / "etc/systemd/system/$name.service.d"
      fi ;;
    selinux)
      echo "mode=$(getenforce)" > "$d/meta" ;;
    file)
      [[ -f $name ]] || die "snapshot: $name missing"
      cp --preserve=all -- "$name" "$d/content"
      { echo "own=$(own_of "$name")"; echo "ctx=$(ctx_of "$name")"; echo "hash=$(hash_of "$name")"; } > "$d/meta" ;;
    dir)
      [[ -d $name ]] || die "snapshot: $name missing"
      tar --selinux --xattrs -cpf "$d/content.tar" -C / "${name#/}"
      { echo "own=$(own_of "$name")"; echo "ctx=$(ctx_of "$name")"; echo "hash=$(hash_dir "$name")"; } > "$d/meta" ;;
    firewall)
      local zone; zone=$(firewall-cmd --get-default-zone)
      firewall-cmd --list-all > "$d/list-all" 2>/dev/null || true
      if [[ -f /etc/firewalld/zones/$zone.xml ]]; then cp --preserve=all "/etc/firewalld/zones/$zone.xml" "$d/zone.xml"; fi
      echo "zone=$zone" > "$d/meta" ;;
    health) : ;;
    *) die "unknown baseline type: $type" ;;
  esac
}

check_item() {  # 0 = matches, 1 = drift (reason logged). No side effects.
  local n=$1 line=$2 id=$3; local d="$REWIND_ROOT/$id/items/$n" type name rest p1 p2 p3 p4 why=""
  IFS=: read -r type name rest <<<"$line"
  IFS=: read -r p1 p2 p3 p4 <<<"$rest"
  case $type in
    service)
      [[ $(systemctl is-enabled "$name" 2>/dev/null || true) == "$p1" ]] || why+="not-$p1 "
      [[ $(systemctl is-active  "$name" 2>/dev/null || true) == active ]] || why+="not-$p2 " ;;
    selinux)
      [[ $(getenforce | tr '[:upper:]' '[:lower:]') == "$p1" ]] || why+="mode=$(getenforce) " ;;
    file|dir)
      if [[ ! -e $name ]]; then why+="missing "
      else
        [[ $(own_of "$name") == "$p1:$p2:$p3" ]] || why+="own=$(own_of "$name") "
        [[ $(ctx_of "$name") == "$p4" ]]        || why+="ctx=$(ctx_of "$name") "
        if [[ -f $d/meta ]]; then
          local want have
          want=$(sed -n 's/^hash=//p' "$d/meta")
          if [[ $type == file ]]; then have=$(hash_of "$name"); else have=$(hash_dir "$name"); fi
          [[ $have == "$want" ]] || why+="content-changed "
        fi
      fi ;;
    firewall)
      firewall-cmd --query-"$name"="$p1" >/dev/null 2>&1             || why+="runtime-missing "
      firewall-cmd --permanent --query-"$name"="$p1" >/dev/null 2>&1 || why+="permanent-missing " ;;
    health)
      bash -c "$rest" >/dev/null 2>&1 || why+="health-check-failed " ;;
  esac
  if [[ -n $why ]]; then log "CHECK FAIL [$n] $type:$name -> $why"; return 1; fi
  return 0
}

restore_item() {
  local n=$1 line=$2 id=$3; local d="$REWIND_ROOT/$id/items/$n" type name rest p1 p2 p3 p4
  IFS=: read -r type name rest <<<"$line"
  IFS=: read -r p1 p2 p3 p4 <<<"$rest"
  case $type in
    service)
      rm -rf -- "/etc/systemd/system/$name.service.d"
      if [[ -f $d/dropins.tar ]]; then tar --selinux -xpf "$d/dropins.tar" -C /; fi
      systemctl daemon-reload
      if [[ $p1 == enabled ]]; then systemctl enable "$name" >/dev/null 2>&1 || true
      else systemctl disable "$name" >/dev/null 2>&1 || true; fi
      if [[ $p2 == running ]]; then
        systemctl restart "$name" || true
        wait_active "$name" 15 || log "restore: $name not active after restart"
      else systemctl stop "$name" || true; fi ;;
    selinux)
      if [[ $p1 == enforcing ]]; then setenforce 1; else setenforce 0; fi ;;
    file)
      cp --preserve=all -- "$d/content" "$name"
      chown "$p1:$p2" -- "$name"; chmod "$p3" -- "$name"; chcon -t "$p4" -- "$name" ;;
    dir)
      tar --selinux --xattrs -xpf "$d/content.tar" -C /
      chown "$p1:$p2" -- "$name"; chmod "$p3" -- "$name"; chcon -t "$p4" -- "$name" ;;
    firewall)
      firewall-cmd -q --permanent --add-"$name"="$p1" >/dev/null
      firewall-cmd -q --add-"$name"="$p1" >/dev/null || true ;;
    health) : ;;
  esac
}
restore_nonsvc() { if [[ $2 == service:* ]]; then return 0; fi; restore_item "$@"; }
restore_svc()    { if [[ $2 != service:* ]]; then return 0; fi; restore_item "$@"; }

# ---- the three primitives --------------------------------------------------
snapshot() {  # snapshot <id>
  local id=$1
  mkdir -p "$REWIND_ROOT/$id/items"
  cp -- "$BASELINE_FILE" "$REWIND_ROOT/$id/manifest"
  date -Is > "$REWIND_ROOT/$id/created"
  each_item snapshot_item "$id"
  ls -1dt "$REWIND_ROOT"/tx-* 2>/dev/null | tail -n +$((KEEP_TX+1)) | xargs -r rm -rf || true
  log "snapshot $id taken"
}

check() {  # check [id] -> 0 all match, 1 drift
  each_item check_item "${1:-baseline}"
}

restore() {  # restore <id> -> config first, services last, then verify
  local id=$1
  [[ -d $REWIND_ROOT/$id ]] || die "no snapshot '$id'"
  each_item restore_nonsvc "$id" || true
  each_item restore_svc "$id"    || true
  if check "$id"; then log "restore $id OK (verified)"; return 0; fi
  log "restore $id: VERIFY FAILED"; return 1
}
