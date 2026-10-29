#!/usr/bin/env bash
# Live lab drive: real fm-watch-arm.sh / fm-watch.sh / fm-wake-drain.sh in a disposable lab home.
# A one-shot mktemp shim makes the stopped watcher's close take 25s (a slow TERM honor).
set -u
ROOT=$1; SLOW=${2:-25}; OBSERVE=${3:-90}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
TMUXD=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
STATE="$LAB/state"; FAKE="$LAB/fakebin"; mkdir -p "$FAKE"
REAL_MKTEMP=$(command -v mktemp)
cat > "$FAKE/mktemp" <<SH
#!/usr/bin/env bash
case "\$*" in */.watcher-down.tmp.XXXXXX) ! rm "$LAB/slow-close" 2>/dev/null || sleep $SLOW ;; esac
exec "$REAL_MKTEMP" "\$@"
SH
chmod +x "$FAKE/mktemp"
export FM_HOME="$LAB" TMUX_TMPDIR="$TMUXD" PATH="$FAKE:$PATH" FM_ARM_CONFIRM_TIMEOUT=60
unset TMUX NO_MISTAKES_GATE FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
ts(){ date +%H:%M:%S; }
cleanup(){ pkill -TERM -f "FM_HOME_MARK_UNUSED" 2>/dev/null; for p in $OWNER $TAKER; do kill -TERM $p 2>/dev/null; done; sleep 2
  w=$(cat "$STATE/.watch.lock/pid" 2>/dev/null); [ -n "$w" ] && kill -TERM "$w" 2>/dev/null; sleep 1
  "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"; echo "[$(ts)] lab removed: $([ -e "$LAB" ] && echo no || echo yes)"; }
OWNER=; TAKER=
trap cleanup EXIT
echo "[$(ts)] lab=$LAB"
"$ROOT/bin/fm-watch-arm.sh" --restart > "$LAB/owner.out" 2>&1 & OWNER=$!
for i in $(seq 1 300); do grep -q '^watcher: started' "$LAB/owner.out" 2>/dev/null && break; sleep 0.1; done
echo "[$(ts)] owner arm: $(cat "$LAB/owner.out")"
# first recovery from fresh home may exist: drain+ack until clean, as main would
drain_ack(){ local err=$LAB/d.err out seq gen; out=$("$ROOT/bin/fm-wake-drain.sh" 2>"$err"); 
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation \(.*\)$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9]* --recovery-generation \(.*\)$/\1/p' "$err")
  echo "[$(ts)] drain stdout: ${out:-<empty>} | stderr: $(tr '\n' ' ' <"$err")"
  [ -n "$seq" ] && "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1 && echo "[$(ts)] acked through $seq gen $gen"; }
. "$ROOT/bin/fm-wake-lib.sh"; fm_wake_append signal lab "signal: lab fixture handled by main"
drain_ack
echo "[$(ts)] .watcher-down after ack: $(cat "$STATE/.watcher-down")"
ACKED=$(cat "$STATE/.watcher-down")
touch "$LAB/slow-close"
echo "[$(ts)] main parks: fm-watch-arm.sh --take-over $OWNER (stopped watcher will take ${SLOW}s to close)"
"$ROOT/bin/fm-watch-arm.sh" --take-over "$OWNER" > "$LAB/taker.out" 2>&1 & TAKER=$!
end=$(( $(date +%s) + SLOW + OBSERVE )); n=0
while [ "$(date +%s)" -lt "$end" ]; do
  if ! kill -0 $TAKER 2>/dev/null; then
    n=$((n+1)); echo "[$(ts)] take-over arm ended (cycle $n): $(tr '\n' ' ' < "$LAB/taker.out")"; drain_ack
    "$ROOT/bin/fm-watch-arm.sh" --take-over "$OWNER" > "$LAB/taker.out" 2>&1 & TAKER=$!
  fi; sleep 1; done
echo "[$(ts)] take-over arm output so far: $(tr '\n' ' ' < "$LAB/taker.out")"
echo "[$(ts)] .watcher-down now: $(cat "$STATE/.watcher-down") (acked was: $ACKED)"
echo "[$(ts)] cycle-exit ledger reasons: $(grep -o 'reason=[a-z-]*' "$STATE/.watch-cycle-exits.log" | tr '\n' ' ')"
echo "RESULT: wake cycles delivered during ${OBSERVE}s observation after slow stop = $n; rearm-resurface lines = $(grep -c 'rearm-resurface' "$LAB"/*.out "$LAB/d.err" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')"
