# shellcheck shell=bash
# Docker helpers for jobs: stopping/starting containers and dumping databases.

UPB_STOPPED_CONTAINERS=()

container_exists() { docker inspect "$1" >/dev/null 2>&1; }
container_running() { [[ $(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null) == true ]]; }

# Stops the given containers in order and remembers which ones it stopped.
# Containers that don't exist or aren't running are skipped.
stop_containers() {
  local c
  for c in "$@"; do
    if ! container_exists "$c"; then
      warn "container '$c' not found, not stopping it"
      continue
    fi
    if ! container_running "$c"; then
      info "container '$c' is not running"
      continue
    fi
    if dry_run; then
      info "[dry-run] docker stop $c"
      continue
    fi
    info "stopping container $c"
    if ! docker stop -t "$CONTAINER_STOP_TIMEOUT" "$c" >/dev/null; then
      error "failed to stop container $c"
      return 1
    fi
    UPB_STOPPED_CONTAINERS+=("$c")
  done
}

# Starts everything stop_containers stopped, in reverse order. Safe to call twice.
restart_stopped_containers() {
  local i c rc=0
  for ((i = ${#UPB_STOPPED_CONTAINERS[@]} - 1; i >= 0; i--)); do
    c=${UPB_STOPPED_CONTAINERS[i]}
    info "starting container $c"
    if ! docker start "$c" >/dev/null; then
      error "failed to restart container $c; start it manually"
      rc=1
    fi
  done
  UPB_STOPPED_CONTAINERS=()
  return "$rc"
}

# docker_exec <container> <command...> — for use in job hooks.
docker_exec() {
  local container=${1:?docker_exec: container required}
  shift
  if dry_run; then
    info "[dry-run] docker exec $container $(quote_args "$@")"
    return 0
  fi
  info "running in $container: $*"
  docker exec "$container" "$@"
}

# dump_postgres <container> [user] [database]
# Writes a gzipped SQL dump to $JOB_DUMP_DIR. Without a database it dumps every
# database in the cluster (pg_dumpall). The previous dump is only replaced once
# the new one has completed.
dump_postgres() {
  local container=${1:?dump_postgres: container required} user=${2:-postgres} db=${3:-}
  local out="$JOB_DUMP_DIR/postgres-${container}${db:+-$db}.sql.gz"
  local -a dump_cmd
  if [[ -n $db ]]; then
    dump_cmd=(pg_dump --username="$user" --dbname="$db" --clean --if-exists)
  else
    dump_cmd=(pg_dumpall --username="$user" --clean --if-exists)
  fi
  if dry_run; then
    info "[dry-run] docker exec $container $(quote_args "${dump_cmd[@]}") | gzip > $out"
    return 0
  fi
  info "dumping postgres ${db:-(all databases)} from $container"
  if docker exec "$container" "${dump_cmd[@]}" | gzip >"$out.partial"; then
    mv -f "$out.partial" "$out"
    info "wrote $out ($(du -h "$out" | cut -f1))"
  else
    rm -f "$out.partial"
    error "postgres dump from $container failed"
    return 1
  fi
}
