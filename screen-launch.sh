#!/bin/sh
usage() {
    printf '%s\n' "usage: screen-launch.sh plan | screen-launch.sh run -- cmd [args...]" >&2
    exit 2
}

menu_running() {
    pids=$("${RGDS_PIDOF:-pidof}" muos2.bin 2>/dev/null || true)
    [ -n "$pids" ]
}

menu_bin() {
    if [ -n "${RGDS_MENU_BIN+x}" ]; then
        if [ -f "$RGDS_MENU_BIN" ] && [ -x "$RGDS_MENU_BIN" ]; then
            printf '%s\n' "$RGDS_MENU_BIN"
            return 0
        fi
        return 1
    fi
    for candidate in \
        /mnt/vendor/ctrl/muos2.bin \
        /mnt/vendor/bin/muos2.bin \
        /usr/bin/muos2.bin
    do
        if [ -f "$candidate" ] && [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

pid_alive() {
    [ -d "/proc/$1" ] || return 1
    state=$(awk '/^State:/ { print $2 }' "/proc/$1/status" 2>/dev/null || true)
    [ -n "$state" ] && [ "$state" != "Z" ]
}

stop_pid() {
    pid=$1
    [ -n "$pid" ] || return 0
    env kill -TERM "$pid" 2>/dev/null || true
    i=0
    while [ "$i" -lt 40 ]; do
        if ! pid_alive "$pid"; then
            wait "$pid" 2>/dev/null || true
            return 0
        fi
        if [ "$i" -eq 20 ]; then
            env kill -KILL "$pid" 2>/dev/null || true
        fi
        sleep 0.05
        i=$((i + 1))
    done
    if ! pid_alive "$pid"; then
        wait "$pid" 2>/dev/null || true
    fi
}

to_absolute() {
    case $1 in
        /*) printf '%s\n' "$1" ;;
        *)
            dir=$(CDPATH= cd -- "$(dirname -- "$1")" && pwd) || return 1
            printf '%s\n' "$dir/$(basename -- "$1")"
            ;;
    esac
}

cmd_plan() {
    if menu_running; then
        printf '%s\n' keep
        return 0
    fi
    bin=$(menu_bin) || {
        printf '%s\n' missing
        return 0
    }
    bin=$(to_absolute "$bin") || {
        printf '%s\n' missing
        return 0
    }
    printf 'start %s\n' "$bin"
}

cmd_run() {
    [ "${1-}" = "--" ] || usage
    shift
    [ "$#" -ge 1 ] || usage
    if menu_running; then
        "$@"
        return $?
    fi
    bin=$(menu_bin) || {
        printf '%s\n' "OS menu binary not found" >&2
        "$@"
        return $?
    }
    bin=$(to_absolute "$bin") || {
        printf '%s\n' "OS menu binary not found" >&2
        "$@"
        return $?
    }
    next=${RGDS_NEXT:-/tmp/.next}
    if [ -f "$next" ]; then
        rm -f -- "$next"
    fi
    (cd -- "$(dirname -- "$bin")" && exec "$bin") >/dev/null 2>&1 &
    menu_pid=$!
    "$@" &
    app_pid=$!
    trap 'env kill -TERM "$app_pid" "$menu_pid" 2>/dev/null || true; exit 1' INT TERM HUP
    wait "$app_pid"
    status=$?
    trap - INT TERM HUP
    stop_pid "$menu_pid"
    return "$status"
}

[ "$#" -ge 1 ] || usage
cmd=$1
shift
case $cmd in
    plan)
        [ "$#" -eq 0 ] || usage
        cmd_plan
        ;;
    run)
        cmd_run "$@"
        ;;
    *)
        usage
        ;;
esac
