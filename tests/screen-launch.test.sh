#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
launch=$root/screen-launch.sh
work=$(mktemp -d)
keep_decoy=
start_decoy=
menu_pid=
term_launch=

cleanup() {
    status=$?
    [ -n "$keep_decoy" ] && /bin/kill "$keep_decoy" 2>/dev/null || true
    [ -n "$start_decoy" ] && /bin/kill "$start_decoy" 2>/dev/null || true
    [ -n "$menu_pid" ] && /bin/kill "$menu_pid" 2>/dev/null || true
    [ -n "$term_launch" ] && /bin/kill "$term_launch" 2>/dev/null || true
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

bin=$work/bin
mkdir -p "$bin"
kill_log=$work/kill.log
touch "$kill_log"
cat > "$bin/kill" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$KILL_LOG"
exec /bin/kill "$@"
EOF
chmod +x "$bin/kill"

cat > "$bin/pidof-keep" <<'EOF'
#!/bin/sh
printf '%s\n' "$DECOY_PID"
EOF
cat > "$bin/pidof-none" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$bin/pidof-keep" "$bin/pidof-none"

cat > "$work/app-keep" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$MARKER"
exit 9
EOF
cat > "$work/app-start" <<'EOF'
#!/bin/sh
deadline=$(($(date +%s) + 2))
while [ "$(date +%s)" -le "$deadline" ]; do
    if grep -q '^menu ' "$ORDER" 2>/dev/null; then
        printf 'app %s\n' "$$" >> "$ORDER"
        exit 4
    fi
    sleep 0.05
done
printf 'app %s timeout\n' "$$" >> "$ORDER"
exit 5
EOF
cat > "$work/app-missing" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$MARKER"
exit 6
EOF
cat > "$work/app-stay" <<'EOF'
#!/bin/sh
trap 'exit 0' INT TERM
printf 'app %s\n' "$$" >> "$ORDER"
fifo=$ORDER.stay.fifo
mkfifo "$fifo"
read _ < "$fifo"
EOF
cat > "$work/menu" <<'EOF'
#!/bin/sh
trap 'exit 0' INT TERM
state=present
if [ ! -e "$RGDS_NEXT" ]; then
    state=absent
fi
printf 'menu %s %s\n' "$$" "$state" >> "$ORDER"
fifo=$ORDER.fifo
mkfifo "$fifo"
read _ < "$fifo"
EOF
chmod +x "$work/app-keep" "$work/app-start" "$work/app-missing" "$work/app-stay" "$work/menu"

export PATH="$bin:$PATH"
export KILL_LOG=$kill_log

env kill -0 $$
[ -s "$kill_log" ] || fail "fake kill was not on PATH"
: > "$kill_log"

sleep 300 &
keep_decoy=$!
keep_next=$work/keep.next
printf 'sentinel\n' > "$keep_next"
keep_marker=$work/keep.marker
plan_out=$(
    DECOY_PID=$keep_decoy \
    RGDS_PIDOF=$bin/pidof-keep \
    RGDS_NEXT=$keep_next \
    "$launch" plan
)
[ "$plan_out" = "keep" ] || fail "plan keep: [$plan_out]"
keep_status=0
keep_stdout=$(
    DECOY_PID=$keep_decoy \
    RGDS_PIDOF=$bin/pidof-keep \
    RGDS_NEXT=$keep_next \
    MARKER=$keep_marker \
    "$launch" run -- "$work/app-keep" ping
) || keep_status=$?
[ "$keep_status" -eq 9 ] || fail "keep status $keep_status"
[ -z "$keep_stdout" ] || fail "keep stdout [$keep_stdout]"
[ ! -s "$kill_log" ] || fail "keep signaled: $(cat "$kill_log")"
[ -d "/proc/$keep_decoy" ] || fail "keep decoy died"
[ "$(cat "$keep_marker")" = "ping" ] || fail "keep app args"
[ -f "$keep_next" ] || fail "keep removed RGDS_NEXT"

sleep 300 &
start_decoy=$!
start_next=$work/start.next
printf 'sentinel\n' > "$start_next"
start_order=$work/start.order
plan_out=$(
    RGDS_PIDOF=$bin/pidof-none \
    RGDS_MENU_BIN=$work/menu \
    RGDS_NEXT=$start_next \
    ORDER=$start_order \
    "$launch" plan
)
[ "$plan_out" = "start $work/menu" ] || fail "plan start: [$plan_out]"
[ ! -s "$start_order" ] || fail "plan started the menu"
[ -f "$start_next" ] || fail "plan removed RGDS_NEXT"
start_status=0
start_err=$work/start.err
: > "$kill_log"
start_stdout=$(
    RGDS_PIDOF=$bin/pidof-none \
    RGDS_MENU_BIN=$work/menu \
    RGDS_NEXT=$start_next \
    ORDER=$start_order \
    "$launch" run -- "$work/app-start" 2>"$start_err"
) || start_status=$?
[ "$start_status" -eq 4 ] || fail "start status $start_status"
[ -z "$start_stdout" ] || fail "start stdout [$start_stdout]"
[ ! -s "$start_err" ] || fail "start stderr [$(cat "$start_err")]"
[ -f "$start_order" ] || fail "start order log missing"
menu_line=$(grep '^menu ' "$start_order" | head -n 1)
app_line=$(grep '^app ' "$start_order" | head -n 1)
[ -n "$menu_line" ] || fail "menu did not record a start"
[ -n "$app_line" ] || fail "app did not record a start"
set -- $menu_line
menu_pid=$2
menu_state=$3
set -- $app_line
app_pid=$2
[ "$menu_state" = "absent" ] || fail "menu saw RGDS_NEXT ($menu_state)"
grep -F -x -- "-TERM $menu_pid" "$kill_log" >/dev/null || fail "kill log [$(cat "$kill_log")]"
if grep -F -- "$start_decoy" "$kill_log" >/dev/null; then
    fail "start killed decoy [$(cat "$kill_log")]"
fi
first=$(head -n 1 "$start_order")
second=$(sed -n '2p' "$start_order")
[ "$first" = "$menu_line" ] || fail "order log first line [$first]"
[ "$second" = "$app_line" ] || fail "order log second line [$second]"
[ ! -f "$start_next" ] || fail "RGDS_NEXT still present"
[ ! -d "/proc/$menu_pid" ] || fail "menu pid $menu_pid still alive"
[ -d "/proc/$start_decoy" ] || fail "start decoy died"
menu_pid=

missing_bin=$work/missing-menu
missing_next=$work/missing.next
printf 'sentinel\n' > "$missing_next"
missing_marker=$work/missing.marker
plan_out=$(
    RGDS_PIDOF=$bin/pidof-none \
    RGDS_MENU_BIN=$missing_bin \
    RGDS_NEXT=$missing_next \
    "$launch" plan
)
[ "$plan_out" = "missing" ] || fail "plan missing: [$plan_out]"
missing_status=0
missing_err=$work/missing.err
missing_stdout=$(
    RGDS_PIDOF=$bin/pidof-none \
    RGDS_MENU_BIN=$missing_bin \
    RGDS_NEXT=$missing_next \
    MARKER=$missing_marker \
    "$launch" run -- "$work/app-missing" pong 2>"$missing_err"
) || missing_status=$?
[ "$missing_status" -eq 6 ] || fail "missing status $missing_status"
[ "$(cat "$missing_err")" = "OS menu binary not found" ] || fail "missing stderr [$(cat "$missing_err")]"
[ "$(cat "$missing_marker")" = "pong" ] || fail "missing app did not run"
[ -f "$missing_next" ] || fail "missing removed RGDS_NEXT"
[ -z "$missing_stdout" ] || fail "missing stdout [$missing_stdout]"

usage_marker=$work/usage.marker
usage_status=0
MARKER=$usage_marker "$launch" run "$work/app-missing" >"$work/usage.out" 2>"$work/usage.err" || usage_status=$?
[ "$usage_status" -eq 2 ] || fail "run without -- status $usage_status"
[ ! -e "$usage_marker" ] || fail "run without -- started the app"
usage_status=0
"$launch" run >"$work/usage2.out" 2>"$work/usage2.err" || usage_status=$?
[ "$usage_status" -eq 2 ] || fail "run with no args status $usage_status"

term_order=$work/term.order
term_next=$work/term.next
printf 'sentinel\n' > "$term_next"
: > "$term_order"
RGDS_PIDOF=$bin/pidof-none \
RGDS_MENU_BIN=$work/menu \
RGDS_NEXT=$term_next \
ORDER=$term_order \
"$launch" run -- "$work/app-stay" >"$work/term.out" 2>"$work/term.err" &
term_launch=$!
deadline=$(($(date +%s) + 3))
while [ "$(date +%s)" -le "$deadline" ]; do
    if grep -q '^menu ' "$term_order" 2>/dev/null && grep -q '^app ' "$term_order" 2>/dev/null; then
        break
    fi
    sleep 0.05
done
grep -q '^menu ' "$term_order" || fail "term test menu did not start [$(cat "$term_err" 2>/dev/null)]"
grep -q '^app ' "$term_order" || fail "term test app did not start"
/bin/kill -TERM "$term_launch"
term_status=0
wait "$term_launch" || term_status=$?
term_launch=
[ "$term_status" -ne 0 ] || fail "TERM exit status $term_status"
set -- $(grep '^menu ' "$term_order" | head -n 1)
term_menu=$2
set -- $(grep '^app ' "$term_order" | head -n 1)
term_app=$2
deadline=$(($(date +%s) + 2))
while [ "$(date +%s)" -le "$deadline" ]; do
    if [ ! -d "/proc/$term_menu" ] && [ ! -d "/proc/$term_app" ]; then
        break
    fi
    sleep 0.05
done
[ ! -d "/proc/$term_menu" ] || fail "term menu $term_menu still alive"
[ ! -d "/proc/$term_app" ] || fail "term app $term_app still alive"

dir_menu=$work/menu-dir
mkdir -p "$dir_menu"
chmod +x "$dir_menu"
plan_out=$(
    RGDS_PIDOF=$bin/pidof-none \
    RGDS_MENU_BIN=$dir_menu \
    "$launch" plan
)
[ "$plan_out" = "missing" ] || fail "plan directory: [$plan_out]"

printf '%s\n' "screen-launch ok"
