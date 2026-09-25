# shellcheck shell=bash
# Notifications: Unraid's notification system and healthchecks.io-style pings.

# notify_unraid <normal|warning|alert> <subject> <description> [message]
notify_unraid() {
  [[ $NOTIFY_UNRAID == true && -x $UNRAID_NOTIFY_CMD ]] || return 0
  local -a args=(-e "Unraid to Proxmox backup" -i "$1" -s "$2" -d "$3")
  [[ -n ${4:-} ]] && args+=(-m "$4")
  "$UNRAID_NOTIFY_CMD" "${args[@]}" >/dev/null 2>&1 || warn "sending the Unraid notification failed"
}

# healthcheck_ping [start|fail] [log-file] — the log tail is sent as the ping body.
healthcheck_ping() {
  [[ -n $HEALTHCHECK_URL ]] || return 0
  local url=${HEALTHCHECK_URL%/}
  [[ -n ${1:-} ]] && url+="/$1"
  local -a args=(-fsS -m 15 --retry 3 -o /dev/null)
  if [[ -n ${2:-} && -r $2 ]]; then
    tail -c 10000 "$2" | curl "${args[@]}" --data-binary @- "$url"
  else
    curl "${args[@]}" "$url"
  fi || warn "healthcheck ping failed: $url"
}
