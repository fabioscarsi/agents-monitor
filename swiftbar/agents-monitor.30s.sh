#!/usr/bin/env bash
# SwiftBar plugin — Agents Monitor
# Filename convention: <name>.<refresh>.sh — "30s" = refresh every 30 seconds.
#
# See README.md in the repo for full design notes and customization knobs.
#
# <swiftbar.title>Agents Monitor</swiftbar.title>
# <swiftbar.author>Fabio Scarsi</swiftbar.author>
# <swiftbar.desc>Monitor user LaunchAgents + brew services. Click to restart/hide/inspect.</swiftbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.dependencies>bash 4+, swiftbar</swiftbar.dependencies>
# <swiftbar.version>0.1.0</swiftbar.version>

# Default macOS /bin/bash is 3.2 — too old for associative arrays. Re-exec under
# Homebrew bash if /usr/bin/env bash gave us anything older than 4.
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$candidate" ]]; then
      exec "$candidate" "$0" "$@"
    fi
  done
  echo "Error: agents-monitor requires bash 4+ (declare -A). Found: ${BASH_VERSION:-unknown}." >&2
  echo "Install via: brew install bash" >&2
  exit 1
fi

# B.2 — SwiftBar's launchd PATH is minimal (/usr/bin:/bin:/usr/sbin:/sbin), so
# `command -v brew` fails and the brew section silently disappears for many
# users. Prepend Homebrew's both-architecture prefixes.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Note: errexit is intentionally OFF. A SwiftBar plugin must always render
# *something* — letting one transient launchctl error abort the whole pass
# would leave the menu bar empty.
set -uo pipefail

# --- Paths (CONFIG_DIR/CACHE_DIR/HELPER overridable via env vars only) ---
CONFIG_DIR="${AGENTS_MONITOR_CONFIG_DIR:-$HOME/.config/agents-monitor}"
CACHE_DIR="${AGENTS_MONITOR_CACHE_DIR:-$HOME/.cache/agents-monitor}"
HELPER="${AGENTS_MONITOR_HELPER:-$HOME/.local/bin/launchctl-user}"
LOCAL_CONF="$CONFIG_DIR/local.conf"
BLOCKLIST="$CONFIG_DIR/blocklist.conf"
STATE="$CACHE_DIR/pids.tsv"
DEBUG="${AGENTS_MONITOR_DEBUG:-0}"

# B.6 — Validate AGENTS_MONITOR_HELPER. It's embedded inside SwiftBar action
# strings (bash="$HELPER"); a malicious value with shell metacharacters could
# inject. Require absolute path with safe characters AND that the file exists
# and is executable.
SAFE_PATH_RE='^/[A-Za-z0-9._/-]+$'
if [[ ! "$HELPER" =~ $SAFE_PATH_RE ]] || [[ ! -x "$HELPER" ]]; then
  # Fall back to the safe default; the helper might still be missing, in which
  # case Restart actions will fail loudly (better than silent injection).
  HELPER="$HOME/.local/bin/launchctl-user"
fi

# --- Defaults (overridable via local.conf — see allowlist parser below) ---
FLAP_WINDOW=120

# Parse local.conf AS DATA (not bash). Allowlist of recognized keys.
if [[ -f "$LOCAL_CONF" ]]; then
  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    line="${raw_line%%#*}"
    line="$(echo "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [[ -z "$line" ]] && continue

    key="${line%%=*}"
    val="${line#*=}"
    key="$(echo "$key" | sed -E 's/[[:space:]]+$//')"
    val="$(echo "$val" | sed -E 's/^[[:space:]]+//')"
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"

    case "$key" in
      FLAP_WINDOW)
        # B.4 — Reject FLAP_WINDOW=0 (was silently disabling flap detection
        # despite "positive integer" promise in local.conf.example).
        if [[ "$val" =~ ^[1-9][0-9]*$ ]]; then
          FLAP_WINDOW="$val"
        fi
        ;;
      *)
        # Unknown key — silently ignore. Future-compatible.
        ;;
    esac
  done < "$LOCAL_CONF"
fi

UID_NUM="$(id -u)"
DOMAIN="gui/${UID_NUM}"
NOW="$(date +%s)"

mkdir -p "$CONFIG_DIR" "$CACHE_DIR"
[[ -f "$BLOCKLIST" ]] || cat > "$BLOCKLIST" <<'EOF'
# Agents Monitor blocklist — one label per line. Lines starting with # are comments.
# Click "Hide" on a service in the menu to append it here automatically.
# Edit this file to remove a label and the service will reappear at next refresh.
# For brew services, the entry is prefixed with `brew/` (e.g. `brew/neo4j`).

EOF

# --- Load blocklist into a set ---
declare -A BLOCKED
while IFS= read -r raw || [[ -n "$raw" ]]; do
  line="${raw%%#*}"
  line="$(echo "$line" | tr -d '[:space:]')"
  [[ -n "$line" ]] && BLOCKED["$line"]=1
done < "$BLOCKLIST"

# --- Label safety check ---
SAFE_LABEL_RE='^[A-Za-z0-9._-]+$'
is_safe_label() { [[ "$1" =~ $SAFE_LABEL_RE ]]; }

# B.9 — Env-gated debug breadcrumb. Logs to stderr (visible in SwiftBar's
# plugin error pane) when a known-loaded service yields no parseable fields.
# Surfaces format drift before it becomes a silent classification outage.
debug_log() {
  [[ "$DEBUG" == "1" ]] && echo "[$(date +%H:%M:%S)] $*" >&2 || true
}

# --- Enumerate user-domain LaunchAgents ---
declare -a SERVICES=()
while IFS= read -r label; do
  [[ -z "$label" ]] && continue
  [[ "$label" =~ ^com\.apple\. ]] && continue
  [[ "$label" =~ ^application\. ]] && continue
  [[ "$label" =~ ^homebrew\.mxcl\. ]] && continue
  [[ -n "${BLOCKED[$label]:-}" ]] && continue
  is_safe_label "$label" || continue
  SERVICES+=("$label")
done < <(launchctl list 2>/dev/null | awk 'NR>1 && $3 != "" {print $3}' | sort -u)

# --- Load previous state ---
declare -A PREV_PID PREV_TS PREV_CLASS
if [[ -f "$STATE" ]]; then
  while IFS=$'\t' read -r key pid ts cls; do
    [[ -z "$key" ]] && continue
    PREV_PID["$key"]="$pid"
    PREV_TS["$key"]="$ts"
    PREV_CLASS["$key"]="${cls:-}"
  done < "$STATE"
fi

icon_to_class() {
  case "$1" in
    "🟢") echo "healthy" ;;
    "🟡") echo "issue" ;;
    "⚫") echo "down" ;;
    "⚪") echo "idle" ;;
    *)    echo "unknown" ;;
  esac
}

# Output: ICON|STATE|DETAIL|CURRENT_PID
classify_agent() {
  local label="$1"
  local out pid last
  out="$(launchctl print "${DOMAIN}/${label}" 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    echo "⚫|absent|not loaded|"
    return
  fi
  pid="$(awk -F'= ' '/^[[:space:]]*pid = /{print $2; exit}' <<<"$out")"
  last="$(awk -F'= ' '/^[[:space:]]*last exit code = /{print $2; exit}' <<<"$out")"

  # B.9 — If launchctl print returned content but neither expected field
  # was found, Apple may have changed the output format. Log it.
  if [[ -z "$pid" && -z "$last" ]]; then
    debug_log "WARN: launchctl print for $label returned non-empty output but no pid/last-exit-code fields — possible format drift"
  fi

  if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
    if [[ -z "$last" || "$last" == "0" || "$last" == "(never exited)" ]]; then
      echo "⚪|idle|loaded, on-demand (not currently running)|"
    else
      echo "⚫|down|loaded, not running (last exit ${last})|"
    fi
    return
  fi

  local prev_pid="${PREV_PID[$label]:-}"
  local prev_ts="${PREV_TS[$label]:-0}"
  local age=$((NOW - prev_ts))
  if [[ -n "$prev_pid" && "$prev_pid" != "$pid" && $age -lt $FLAP_WINDOW ]]; then
    echo "🟡|flapping|pid ${prev_pid}→${pid} in ${age}s|${pid}"
    return
  fi

  if [[ -n "$last" && "$last" != "0" && "$last" != "(never exited)" ]]; then
    echo "🟡|degraded|running (pid ${pid}), last exit ${last}|${pid}"
  else
    echo "🟢|healthy|pid ${pid}|${pid}"
  fi
}

is_degradation() {
  local prev="$1" curr="$2"
  [[ -z "$prev" ]] && return 1
  case "$curr" in
    issue) [[ "$prev" == "healthy" || "$prev" == "idle" ]] && return 0 ;;
    down)  [[ "$prev" != "down" ]] && return 0 ;;
  esac
  return 1
}

# --- Build status (bucketed by severity) ---
total=0; ok=0; issues=0; down=0; idle=0
declare -a BUCKET_ISSUES=() BUCKET_DOWN=() BUCKET_HEALTHY=() BUCKET_IDLE=()
declare -a NEW_STATE=()
declare -a LABELS_ISSUES=() LABELS_DOWN=()
declare -a DEGRADATIONS=()

build_block() {
  local icon="$1" svc="$2" state="$3" detail="$4"
  local block=""
  block+="${icon} ${svc} — ${state} (${detail}) | color=labelColor"$'\n'
  block+="-- Restart | bash=\"${HELPER}\" param1=\"restart\" param2=\"${svc}\" refresh=true terminal=false"$'\n'
  block+="-- Hide from monitor | shell=\"/bin/zsh\" param1=\"-c\" param2=\"echo '${svc}' >> \\\"${BLOCKLIST}\\\"\" refresh=true terminal=false"$'\n'
  block+="-- Show details (launchctl print) | shell=\"/bin/zsh\" param1=\"-c\" param2=\"launchctl print '${DOMAIN}/${svc}'; echo; echo '--- press any key ---'; read -k1\" terminal=true"
  printf '%s' "$block"
}

build_brew_block() {
  local icon="$1" name="$2" state="$3"
  local block=""
  block+="${icon} brew/${name} — ${state} | color=labelColor"$'\n'
  block+="-- Restart | shell=\"/bin/zsh\" param1=\"-c\" param2=\"brew services restart '${name}'\" refresh=true terminal=false"$'\n'
  block+="-- Hide from monitor | shell=\"/bin/zsh\" param1=\"-c\" param2=\"echo 'brew/${name}' >> \\\"${BLOCKLIST}\\\"\" refresh=true terminal=false"$'\n'
  block+="-- Show details (brew services info) | shell=\"/bin/zsh\" param1=\"-c\" param2=\"brew services info '${name}'; echo; echo '--- press any key ---'; read -k1\" terminal=true"
  printf '%s' "$block"
}

for svc in "${SERVICES[@]}"; do
  IFS='|' read -r icon state detail cur_pid <<< "$(classify_agent "$svc")"
  total=$((total+1))
  cur_class="$(icon_to_class "$icon")"
  prev_class="${PREV_CLASS[$svc]:-}"

  if is_degradation "$prev_class" "$cur_class"; then
    DEGRADATIONS+=("${svc}: ${prev_class} → ${cur_class} (${state})")
  fi

  block="$(build_block "$icon" "$svc" "$state" "$detail")"

  case "$icon" in
    "🟢") ok=$((ok+1));     BUCKET_HEALTHY+=("$block") ;;
    "🟡") issues=$((issues+1)); BUCKET_ISSUES+=("$block");  LABELS_ISSUES+=("$svc") ;;
    "⚫") down=$((down+1));   BUCKET_DOWN+=("$block");    LABELS_DOWN+=("$svc") ;;
    "⚪") idle=$((idle+1));   BUCKET_IDLE+=("$block") ;;
  esac

  prev_pid="${PREV_PID[$svc]:-}"
  prev_ts="${PREV_TS[$svc]:-$NOW}"
  if [[ -n "$cur_pid" && "$cur_pid" != "$prev_pid" ]]; then
    NEW_STATE+=("${svc}"$'\t'"${cur_pid}"$'\t'"${NOW}"$'\t'"${cur_class}")
  elif [[ -n "$cur_pid" ]]; then
    NEW_STATE+=("${svc}"$'\t'"${cur_pid}"$'\t'"${prev_ts}"$'\t'"${cur_class}")
  else
    NEW_STATE+=("${svc}"$'\t\t'"${NOW}"$'\t'"${cur_class}")
  fi
done

# --- Brew services ---
declare -a BREW_ISSUES=() BREW_DOWN=() BREW_HEALTHY=() BREW_IDLE=()
declare -a BREW_NAMES_DOWN=()
if command -v brew >/dev/null 2>&1; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^Name ]] && continue
    name="$(awk '{print $1}' <<<"$line")"
    state="$(awk '{print $2}' <<<"$line")"
    [[ -z "$name" ]] && continue
    [[ -n "${BLOCKED[brew/$name]:-}" ]] && continue
    is_safe_label "$name" || continue

    case "$state" in
      started)   icon="🟢" ;;
      error)     icon="⚫" ;;
      stopped)   icon="⚪" ;;
      none)      icon="⚪" ;;
      scheduled) icon="🟢" ;;
      *)         icon="⚪" ;;
    esac

    cur_class="$(icon_to_class "$icon")"
    state_key="brew/${name}"
    prev_class="${PREV_CLASS[$state_key]:-}"

    if is_degradation "$prev_class" "$cur_class"; then
      DEGRADATIONS+=("brew/${name}: ${prev_class} → ${cur_class} (${state})")
    fi

    bblock="$(build_brew_block "$icon" "$name" "$state")"

    case "$icon" in
      "🟢") ok=$((ok+1));     BREW_HEALTHY+=("$bblock") ;;
      "⚫") down=$((down+1)); BREW_DOWN+=("$bblock"); BREW_NAMES_DOWN+=("$name") ;;
      "⚪") idle=$((idle+1)); BREW_IDLE+=("$bblock") ;;
    esac
    total=$((total+1))

    NEW_STATE+=("${state_key}"$'\t\t'"${NOW}"$'\t'"${cur_class}")
  done < <(brew services list 2>/dev/null)
fi

# --- Persist state ---
{ for line in "${NEW_STATE[@]}"; do printf '%s\n' "$line"; done; } > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"

# --- Fire macOS notification on degradation events ---
# B.8 — Pass the message via osascript argv (item 1 of argv) instead of inline
# string interpolation. Eliminates AppleScript escaping concerns entirely:
# newlines, quotes, backslashes, and control chars are all delivered as data.
if [[ ${#DEGRADATIONS[@]} -gt 0 ]]; then
  msg=""
  for d in "${DEGRADATIONS[@]}"; do
    if [[ -z "$msg" ]]; then msg="$d"; else msg="$msg"$'\n'"$d"; fi
  done
  osascript \
    -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title "Agents Monitor" subtitle (item 2 of argv)' \
    -e 'end run' \
    -- "$msg" "${#DEGRADATIONS[@]} service(s) degraded" 2>/dev/null || true
fi

# --- Header ---
if [[ $down -gt 0 ]]; then
  header="⚫ ${ok}/${total}"
elif [[ $issues -gt 0 ]]; then
  header="🟡 ${ok}/${total}"
else
  header="🟢 ${total}"
fi

# --- Helpers ---
render_blocks() {
  local -n arr=$1
  for blk in "${arr[@]}"; do echo "$blk"; done
}

render_blocks_nested() {
  local -n arr=$1
  for blk in "${arr[@]}"; do
    while IFS= read -r line; do
      if [[ "$line" == "-- "* ]]; then
        echo "----${line:2}"
      else
        echo "-- ${line}"
      fi
    done <<< "$blk"
  done
}

# C.5 — Build "Restart all" actions using the helper's restart-many subcommand
# instead of composing zsh -c shell text. Each label becomes a paramN= entry,
# so SwiftBar handles quoting.
build_restart_many_action() {
  local title="$1"
  shift
  local idx=2  # bash="$HELPER" param1=restart-many param2=label1 param3=label2 ...
  local action="${title} | bash=\"${HELPER}\" param1=\"restart-many\""
  local i=2
  for lbl in "$@"; do
    action+=" param${i}=\"${lbl}\""
    i=$((i+1))
  done
  action+=" refresh=true terminal=false"
  echo "$action"
}

restart_all_issues_action=""
if [[ ${#LABELS_ISSUES[@]} -gt 0 ]]; then
  restart_all_issues_action="$(build_restart_many_action "🔁 Restart all 🟡 issues (${issues})" "${LABELS_ISSUES[@]}")"
fi

# Down still mixes LaunchAgents (via helper) with brew services (separate cmd).
# Brew restart-all stays as a shell composition; brew names are filtered through
# is_safe_label so injection is bounded.
restart_all_down_action=""
if [[ ${#LABELS_DOWN[@]} -gt 0 || ${#BREW_NAMES_DOWN[@]} -gt 0 ]]; then
  if [[ ${#BREW_NAMES_DOWN[@]} -eq 0 ]]; then
    # Pure LaunchAgent down — use restart-many
    restart_all_down_action="$(build_restart_many_action "🔁 Restart all ⚫ down ($((${#LABELS_DOWN[@]}+${#BREW_NAMES_DOWN[@]})))" "${LABELS_DOWN[@]}")"
  else
    # Mixed: build a tiny zsh chain. Brew names already validated.
    parts=()
    if [[ ${#LABELS_DOWN[@]} -gt 0 ]]; then
      labels_args=""
      for l in "${LABELS_DOWN[@]}"; do labels_args+=" '${l}'"; done
      parts+=("'${HELPER}' restart-many${labels_args}")
    fi
    for n in "${BREW_NAMES_DOWN[@]}"; do parts+=("brew services restart '${n}'"); done
    cmd=""
    for p in "${parts[@]}"; do
      if [[ -z "$cmd" ]]; then cmd="$p"; else cmd="$cmd && $p"; fi
    done
    restart_all_down_action="🔁 Restart all ⚫ down ($((${#LABELS_DOWN[@]}+${#BREW_NAMES_DOWN[@]}))) | shell=\"/bin/zsh\" param1=\"-c\" param2=\"${cmd}\" refresh=true terminal=false"
  fi
fi

# --- Render ---
echo "$header"
echo "---"
echo "🩺 Agents Monitor — ${ok} ok, ${issues} issues, ${down} down, ${idle} idle | size=12"
echo "**🟢 healthy   🟡 issue   ⚫ down   ⚪ idle** | md=true size=12 color=labelColor bash=\"/usr/bin/true\" terminal=false"
echo "---"

render_blocks BUCKET_ISSUES
render_blocks BUCKET_DOWN
render_blocks BUCKET_HEALTHY

if [[ ${#BUCKET_IDLE[@]} -gt 0 ]]; then
  echo "⚪ ${#BUCKET_IDLE[@]} idle services (loaded, on-demand) | color=labelColor bash=\"/usr/bin/true\" terminal=false"
  render_blocks_nested BUCKET_IDLE
fi

if [[ $((${#BREW_ISSUES[@]} + ${#BREW_DOWN[@]} + ${#BREW_HEALTHY[@]} + ${#BREW_IDLE[@]})) -gt 0 ]]; then
  echo "---"
  echo "Brew services | size=11 color=gray"
  render_blocks BREW_ISSUES
  render_blocks BREW_DOWN
  render_blocks BREW_HEALTHY
  if [[ ${#BREW_IDLE[@]} -gt 0 ]]; then
    echo "⚪ ${#BREW_IDLE[@]} idle brew services | color=labelColor bash=\"/usr/bin/true\" terminal=false"
    render_blocks_nested BREW_IDLE
  fi
fi

echo "---"
[[ -n "$restart_all_issues_action" ]] && echo "$restart_all_issues_action"
[[ -n "$restart_all_down_action" ]] && echo "$restart_all_down_action"
echo "Refresh now | refresh=true"
echo "Edit blocklist | bash=\"open\" param1=\"-t\" param2=\"$BLOCKLIST\" terminal=false"
BLOCKED_COUNT=$(grep -cE '^[^#[:space:]]' "$BLOCKLIST" 2>/dev/null)
BLOCKED_COUNT=${BLOCKED_COUNT:-0}
echo "Show blocklist (${BLOCKED_COUNT} entries) | shell=\"/bin/zsh\" param1=\"-c\" param2=\"cat \\\"${BLOCKLIST}\\\"; echo; echo '--- press any key ---'; read -k1\" terminal=true"
