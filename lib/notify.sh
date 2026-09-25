# shellcheck shell=bash
# Notifications: email (this host's sendmail), ntfy, and healthchecks.io-style pings.

# notify <failure|success> <subject> <body>
notify() {
  local kind=$1 subject=$2 body=$3
  if [[ -n $NOTIFY_EMAIL ]]; then
    if command -v "$SENDMAIL_CMD" >/dev/null; then
      printf 'To: %s\nSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' \
        "$NOTIFY_EMAIL" "$subject" "$body" | "$SENDMAIL_CMD" -t || warn "sending the email failed"
    else
      warn "NOTIFY_EMAIL is set but $SENDMAIL_CMD was not found"
    fi
  fi
  if [[ -n $NOTIFY_NTFY_URL ]]; then
    local priority=default
    [[ $kind == failure ]] && priority=high
    curl -fsS -m 15 --retry 3 -o /dev/null -H "Title: $subject" -H "Priority: $priority" \
      --data-binary "$body" "$NOTIFY_NTFY_URL" || warn "sending the ntfy notification failed"
  fi
  return 0
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
