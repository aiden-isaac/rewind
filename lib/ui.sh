C_G=$'\e[32m' C_R=$'\e[31m' C_Y=$'\e[33m' C_B=$'\e[36m' C_0=$'\e[0m'
[[ -t 1 ]] || C_G= C_R= C_Y= C_B= C_0=

cmd_status() {
  local n=0 line why rc=0
  echo "baseline:  $BASELINE_FILE"
  echo "verified:  $(cat "$REWIND_ROOT/baseline/created" 2>/dev/null || echo none)"
  echo "daemon:    $(systemctl is-active rewind-drift.timer 2>/dev/null || true) (every 10s, ${REWIND_STRIKES} strikes)   pending trial: $(cat "$PENDING" 2>/dev/null || echo none)"
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* ]] && continue
    n=$((n+1))
    if why=$(check_item "$n" "$line" baseline 2>&1); then
      printf '  %s[ok]%s %s\n' "$C_G" "$C_0" "$line"
    else
      rc=1; printf '  %s[!!]%s %s  %s(%s)%s\n' "$C_R" "$C_0" "$line" "$C_Y" "${why##*-> }" "$C_0"
    fi
  done < "$REWIND_ROOT/baseline/manifest"
  return $rc
}

cmd_log() {
  [[ -s $TIMELINE ]] || { echo "(timeline empty)"; exit 0; }
  local ts kind id ev detail c
  tail -n "${1:-30}" "$TIMELINE" | while IFS=$'\t' read -r ts kind id ev detail; do
    case $ev in
      COMMIT|CONFIRM|CORRECTED|ROLLED_BACK) c=$C_G ;;
      REVERT|REVERTED|EXPIRED|DETECTED)    c=$C_R ;;
      CORRELATED)                          c=$C_Y ;;
      *)                                   c=$C_B ;;
    esac
    printf '%s  %-5s %-16s %s%-11s%s %s\n' "${ts:11:8}" "$kind" "$id" "$c" "$ev" "$C_0" "$detail"
  done
}

health_failed() {  # names the health check(s) failing right now
  local line type name rest
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line == health:* ]] || continue
    IFS=: read -r type name rest <<<"$line"
    bash -c "$rest" >/dev/null 2>&1 || printf '%s ' "$name"
  done < "$BASELINE_FILE"
}

service_hints() {  # journal tail for any baseline service that is not active
  local line type name rest
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line == service:* ]] || continue
    IFS=: read -r type name rest <<<"$line"
    systemctl is-active --quiet "$name" && continue
    echo "--- $name is not active; last journal lines:"
    journalctl -u "$name" -n 6 --no-pager -o cat 2>/dev/null || true
  done < "$BASELINE_FILE"
}

cmd_run() {
  [[ $# -gt 0 ]] || usage
  local id="tx-$(date +%s)" rc reason="" clue out
  out="$REWIND_ROOT/$id/output"
  exec 9>"$LOCK_FILE"; flock 9; trap 'flock -u 9' EXIT
  snapshot "$id"
  timeline TX "$id" START "$WHO: $*"
  set +e; "$@" 2>&1 | tee "$out"; rc=${PIPESTATUS[0]}; set -e
  if (( rc != 0 )) || ! health_ok 10; then
    service_hints >> "$out" 2>&1 || true
    clue=$(grep -m1 -iE 'syntax error|invalid command|denied|no such file|cannot' "$out" \
        || grep -m1 -i 'fail' "$out" || tail -n 1 "$out")
    if (( rc != 0 )); then reason="exit $rc: $clue"
    else reason="health failed after 10s [$(health_failed)]: $clue"; fi
  fi
  if [[ -z $reason ]]; then
    snapshot baseline
    timeline TX "$id" COMMIT "$WHO: $* (exit 0, health ok)"
  else
    printf '%s\n' "$reason" > "$REWIND_ROOT/$id/reason"
    timeline TX "$id" REVERT "$reason"
    restore "$id" || true
    timeline TX "$id" REVERTED "back at pre-change state (details: rewind why $id)"
    exit 1
  fi
}

cmd_why() {
  local id=${1:-$(ls -1dt "$REWIND_ROOT"/tx-* 2>/dev/null | head -1 | xargs -r basename)}
  [[ -n $id && -d $REWIND_ROOT/$id ]] || die "no such transaction"
  echo "== $id  taken $(cat "$REWIND_ROOT/$id/created")"
  echo "== outcome: $(cat "$REWIND_ROOT/$id/reason" 2>/dev/null || echo committed)"
  echo "== command output:"; sed 's/^/   /' "$REWIND_ROOT/$id/output" 2>/dev/null || echo "   (none)"
  echo "== items covered by this snapshot:"; sed 's/^/   /' "$REWIND_ROOT/$id/manifest"
}

log() {
  logger -t rewind -- "$*"
  local c=$'\e[36m' z=$'\e[0m'
  case "$*" in
    *FATAL*|*FAIL*|*REVERT*|*EXPIRED*|*DETECTED*)              c=$'\e[31m' ;;
    *COMMIT*|*CONFIRM*|*" OK"*|*CORRECTED*|*ROLLED_BACK*)      c=$'\e[32m' ;;
    *CORRELATED*|*observed*|*"reverts in"*)                    c=$'\e[33m' ;;
  esac
  [[ -t 2 ]] || { c=; z=; }
  printf '%srewind: %s%s\n' "$c" "$*" "$z" >&2
}
