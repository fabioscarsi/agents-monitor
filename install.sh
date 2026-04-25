#!/usr/bin/env bash
# Agents Monitor — installer
# Idempotent. Re-running upgrades scripts but never overwrites your blocklist.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BIN_DIR="$HOME/.local/bin"
SHARE_DIR="$HOME/.local/share/agents-monitor"
CONFIG_DIR="$HOME/.config/agents-monitor"
CACHE_DIR="$HOME/.cache/agents-monitor"
PLUGIN_FILENAME="agents-monitor.30s.sh"
MANAGED_PLUGIN_DIR="$SHARE_DIR/swiftbar"
MANAGED_PLUGIN_PATH="$MANAGED_PLUGIN_DIR/$PLUGIN_FILENAME"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "  ✓ $*"; }
warn() { echo "  ! $*" >&2; }

echo "Agents Monitor installer"
echo "========================"

# B.1 — Comprehensive PREFLIGHT before any state-changing operation.
# If anything fails here, we exit BEFORE touching disk.
echo
echo "Preflight (no changes will be made):"

# 1. Homebrew
if ! command -v brew >/dev/null 2>&1; then
  cat >&2 <<EOF
Homebrew not found.
This installer does not bootstrap Homebrew (doing so non-interactively from a
script is unsafe). Please install Homebrew first by running the official
install command from https://brew.sh and then re-run this installer.
EOF
  exit 1
fi
info "Homebrew detected at $(command -v brew)"

# 2. bash 4+
HAS_BASH4=0
BASH4_PATH=""
for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
  if [[ -x "$candidate" ]]; then
    HAS_BASH4=1
    BASH4_PATH="$candidate"
    break
  fi
done
if [[ $HAS_BASH4 -eq 0 ]]; then
  echo
  echo "  bash 4+ is required (default macOS /bin/bash is 3.2)."
  read -r -p "  Install via 'brew install bash'? [Y/n] " ans
  case "${ans:-Y}" in
    n|N) die "Cannot proceed without bash 4+." ;;
    *)   brew install bash ;;
  esac
  for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$candidate" ]] && BASH4_PATH="$candidate" && break
  done
  [[ -n "$BASH4_PATH" ]] || die "bash install completed but executable not found."
fi
info "bash 4+ available at $BASH4_PATH"

# 3. SwiftBar
SWIFTBAR_NEWLY_INSTALLED=0
if [[ ! -d "/Applications/SwiftBar.app" ]]; then
  echo
  echo "  SwiftBar.app not found in /Applications/."
  read -r -p "  Install via 'brew install --cask swiftbar'? [Y/n] " ans
  case "${ans:-Y}" in
    n|N) warn "Skipping SwiftBar install. The plugin will still be installed; you'll need to set up SwiftBar manually later." ;;
    *)   brew install --cask swiftbar; SWIFTBAR_NEWLY_INSTALLED=1 ;;
  esac
else
  info "SwiftBar detected at /Applications/SwiftBar.app"
fi

# 4. B.7 — parent dir security check on $BIN_DIR
# launchctl-user is invoked from SwiftBar menu actions; if its parent dir is
# group/world-writable or owned by another user, an attacker who shares the
# system can replace the helper between install and click.
check_safe_parent() {
  local d="$1"
  # Walk up to first existing ancestor.
  while [[ ! -e "$d" && "$d" != "/" ]]; do
    d="$(dirname "$d")"
  done
  [[ -e "$d" ]] || return 0   # /home not even existing → nothing to check
  local owner perm
  owner="$(stat -f '%u' "$d" 2>/dev/null || echo unknown)"
  perm="$(stat -f '%Lp' "$d" 2>/dev/null || echo 0)"
  if [[ "$owner" != "$(id -u)" && "$owner" != "0" ]]; then
    die "Parent directory '$d' is owned by uid=$owner, not your user (uid=$(id -u)). Refusing to install — risk of helper-replacement attack."
  fi
  # Strip the file-mode prefix; check group/world write bits on the dir itself.
  # %Lp is the lower 3 octal digits.
  local g_w=$(( (perm / 10 % 10) & 2 ))
  local o_w=$(( (perm % 10) & 2 ))
  if [[ $g_w -ne 0 || $o_w -ne 0 ]]; then
    warn "Parent directory '$d' has group or world write bits set (perms=$perm)."
    warn "This is a tampering risk. Consider: chmod go-w '$d'"
  fi
}

check_safe_parent "$BIN_DIR"
info "Parent directory ownership/permissions OK for $BIN_DIR"

# 5. SwiftBar PluginDirectory preflight (decide install path BEFORE copying)
EXISTING_DIR="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
if [[ "${EXISTING_DIR:-}" == "~"* ]]; then
  EXISTING_DIR="${HOME}${EXISTING_DIR:1}"
fi

# Resolve PLUGIN_LIVE_DIR and validate it.
# C.1 — When SwiftBar already has a different PluginDirectory, install plugin
# into our managed dir and place a SYMLINK in the user's PluginDirectory. One
# source of truth, clean updates, clean uninstall.
USE_SYMLINK=0
if [[ -z "${EXISTING_DIR:-}" || "$EXISTING_DIR" == "$MANAGED_PLUGIN_DIR" ]]; then
  PLUGIN_LIVE_DIR="$MANAGED_PLUGIN_DIR"
  PLUGIN_LIVE_PATH="$MANAGED_PLUGIN_PATH"
  CONFIGURE_DEFAULTS=1
else
  USE_SYMLINK=1
  PLUGIN_LIVE_DIR="$EXISTING_DIR"
  PLUGIN_LIVE_PATH="$EXISTING_DIR/$PLUGIN_FILENAME"
  CONFIGURE_DEFAULTS=0
  # Validate user's PluginDirectory before committing.
  if [[ ! -d "$EXISTING_DIR" ]]; then
    die "SwiftBar's PluginDirectory '$EXISTING_DIR' does not exist. Create it or reset SwiftBar config."
  fi
  if [[ ! -w "$EXISTING_DIR" ]]; then
    die "SwiftBar's PluginDirectory '$EXISTING_DIR' is not writable by you."
  fi
  info "SwiftBar already configured with PluginDirectory: $EXISTING_DIR"
fi

# Verify all source files exist before any copy.
for f in \
  "$REPO_DIR/bin/launchctl-user" \
  "$REPO_DIR/bin/agents-monitor-uninstall" \
  "$REPO_DIR/swiftbar/$PLUGIN_FILENAME" \
  "$REPO_DIR/etc/blocklist.conf.example" \
  "$REPO_DIR/etc/local.conf.example"; do
  [[ -f "$f" ]] || die "Source file missing in repo: $f"
done
info "All source files present in repo"

echo
echo "Preflight passed. Proceeding with install."

# --- File install (state-changing operations from here) ---
echo
echo "Installing files:"

mkdir -p "$BIN_DIR" "$MANAGED_PLUGIN_DIR" "$CONFIG_DIR" "$CACHE_DIR"

cp -f "$REPO_DIR/bin/launchctl-user"             "$BIN_DIR/launchctl-user"
cp -f "$REPO_DIR/bin/agents-monitor-uninstall"   "$BIN_DIR/agents-monitor-uninstall"
chmod +x "$BIN_DIR/launchctl-user" "$BIN_DIR/agents-monitor-uninstall"
info "$BIN_DIR/launchctl-user"
info "$BIN_DIR/agents-monitor-uninstall"

# Plugin always lives in our managed dir.
cp -f "$REPO_DIR/swiftbar/$PLUGIN_FILENAME" "$MANAGED_PLUGIN_PATH"
chmod +x "$MANAGED_PLUGIN_PATH"
info "$MANAGED_PLUGIN_PATH"

# Create blocklist only if missing — never overwrite user edits.
if [[ -f "$CONFIG_DIR/blocklist.conf" ]]; then
  info "$CONFIG_DIR/blocklist.conf (already exists — preserved)"
else
  cp "$REPO_DIR/etc/blocklist.conf.example" "$CONFIG_DIR/blocklist.conf"
  info "$CONFIG_DIR/blocklist.conf (initialized from example)"
fi

cp -f "$REPO_DIR/etc/local.conf.example" "$CONFIG_DIR/local.conf.example"
info "$CONFIG_DIR/local.conf.example"

# --- SwiftBar plugin directory configuration ---
echo
echo "SwiftBar plugin directory:"

if [[ $CONFIGURE_DEFAULTS -eq 1 ]]; then
  defaults write com.ameba.SwiftBar PluginDirectory -string "$MANAGED_PLUGIN_DIR"
  info "Configured PluginDirectory: $MANAGED_PLUGIN_DIR"
else
  # C.1 — Symlink from user's PluginDirectory to our managed plugin file.
  if [[ -L "$PLUGIN_LIVE_PATH" ]]; then
    rm -f "$PLUGIN_LIVE_PATH"
  elif [[ -f "$PLUGIN_LIVE_PATH" ]]; then
    # Existing regular file (probably from an older installer version) — replace.
    rm -f "$PLUGIN_LIVE_PATH"
  fi
  ln -s "$MANAGED_PLUGIN_PATH" "$PLUGIN_LIVE_PATH"
  info "Symlinked: $PLUGIN_LIVE_PATH -> $MANAGED_PLUGIN_PATH"
  # Drop a pointer so the uninstaller knows where to look
  echo "$PLUGIN_LIVE_PATH" > "$SHARE_DIR/.plugin-installed-at"
fi
info "Plugin live at: $PLUGIN_LIVE_PATH"

# --- Launch SwiftBar ---
echo
if pgrep -x SwiftBar >/dev/null 2>&1; then
  info "SwiftBar already running. Trigger refresh from its menu, or run: open -a SwiftBar"
else
  echo "Launching SwiftBar..."
  open -a SwiftBar
  if [[ $SWIFTBAR_NEWLY_INSTALLED -eq 1 ]]; then
    warn "On first launch SwiftBar may ask for Accessibility / Notifications permissions."
    warn "Grant them in System Settings → Privacy & Security if prompted."
  fi
fi

# --- Done ---
echo
echo "Done."
echo
echo "Next steps:"
echo "  1. Look for the Agents Monitor item in your macOS menu bar (top right)"
echo "  2. Edit ~/.config/agents-monitor/blocklist.conf to hide unwanted services"
echo "     (or click 'Hide from monitor' in the per-service submenu)"
echo "  3. Optional: copy ~/.config/agents-monitor/local.conf.example to local.conf"
echo "     to override defaults (e.g. flap detection window)"
echo
echo "If notifications never fire on a degradation event, grant Notifications"
echo "permission to SwiftBar in System Settings → Notifications → SwiftBar."
echo
echo "To uninstall later: $BIN_DIR/agents-monitor-uninstall"
echo "Add --purge to also remove your blocklist + local.conf."
