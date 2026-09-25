REWIND_CORRELATE="${REWIND_CORRELATE:-180}"   # seconds after a commit during which a behavioral failure is blamed on it

last_commit() {  # most recent committed transaction id, if any
  [[ -f $TIMELINE ]] || return 0
  awk -F'\t' '($2=="TX" && $4=="COMMIT" && $3 ~ /^tx-/) || ($2=="TRIAL" && $4=="CONFIRM") {id=$3} END{print id}' "$TIMELINE"
}

cmd_drift() {   # called by rewind-drift.timer
  if [[ -f $PENDING ]]; then exit 0; fi
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then exit 0; fi
  [[ -d $REWIND_ROOT/baseline ]] || exit 0
  local reasons n
  if reasons=$(check baseline 2>&1); then echo 0 > "$STRIKES_FILE"; exit 0; fi
  n=$(( $(cat "$STRIKES_FILE" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STRIKES_FILE"
  if (( n < REWIND_STRIKES )); then log "drift observed ($n/$REWIND_STRIKES), waiting for confirmation"; exit 0; fi
  echo 0 > "$STRIKES_FILE"
  local id="drift-$(date +%s)" last age
  timeline DRIFT "$id" DETECTED "$(echo "$reasons" | sed 's/^rewind: CHECK FAIL //' | tr '\n' ';')"

  # Behavioral failure (service/health only, config intact) shortly after a commit?
  # Then the commit is the suspect: roll it back instead of restarting into the same fault.
  last=$(last_commit)
  if [[ -n $last && -d $REWIND_ROOT/$last ]] && ! grep -qE '\] (file|dir|selinux|firewall):' <<<"$reasons"; then
    age=$(( $(date +%s) - ${last#tx-} ))
    if (( age <= REWIND_CORRELATE )); then
      timeline DRIFT "$id" CORRELATED "failure ${age}s after $last passed its health check; rolling back that change"
      restore "$last" || true
      snapshot baseline
      timeline DRIFT "$id" ROLLED_BACK "$last undone; baseline reset to last verified-good"
      exit 0
    fi
  fi
  restore baseline || true
  timeline DRIFT "$id" CORRECTED "restored baseline"
}
