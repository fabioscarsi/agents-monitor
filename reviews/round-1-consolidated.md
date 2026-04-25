# Round 1 Peer Review — Consolidated Findings

Reviewers: Mara Weston (architectural), Case Gibson (technical), Hermes/TMCP (security).
Date: 2026-04-25
Coordinator: Claude Code

Pre-existing internal critic pass (43 findings, top-13 already applied) — see `critic-review.md`. This document captures the additional value from the three-agent peer review.

---

## A. Convergent findings (multiple reviewers, highest priority)

### A.1 — `bin/launchctl-user` lacks `is_safe_label` validation
**Convergent: Case #9 (S) + Hermes #16 (S).**
The plugin enforces `^[A-Za-z0-9._-]+$` on every label before embedding in shell strings. The helper does NOT enforce the same — caller (plugin) and callee (helper) have asymmetric trust assumptions. A user invoking `launchctl-user restart 'evil$cmd'` from CLI (or any future caller) bypasses the plugin's defense.
**Fix:** Add `is_safe_label` check at top of helper before any `launchctl` call.

### A.2 — Uninstall destroys `~/.config/agents-monitor` (blocklist + local.conf) without disclosure
**Convergent: Mara #3 (M) + Hermes #21 (N).**
`bin/agents-monitor-uninstall:83-85` recursively removes the user's config directory, including their hand-curated blocklist and any local overrides. README does not warn. Prevents trust on a "try it then uninstall" flow.
**Fix:** Either (a) preserve config by default with explicit `--purge` flag, or (b) prominently document the loss in README + uninstall prompt.

---

## B. BLOCKING / MUST-FIX (Round 1 verdict)

### B.1 — Installer non-transactional (Mara WEAKEST POINT)
Modifies `~/.local/bin`, `~/.config`, SwiftBar defaults, plugin dir without rollback or full preflight. Partial failure leaves mixed state with no diagnostic.
**Fix:** Single comprehensive preflight phase BEFORE any copy. Validate: live plugin dir existence/writability, parent dir permissions, helper path safety, brew availability, defaults write capability.

### B.2 — `swiftbar/agents-monitor.30s.sh:269` — `command -v brew` fails under SwiftBar launchd PATH (Case M)
Default launchd PATH is `/usr/bin:/bin:/usr/sbin:/sbin` — no Homebrew. Brew section silently disappears for many users.
**Fix:** Explicit `export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"` near top of script.

### B.3 — `install.sh:121-124` — EXISTING_DIR not preflighted before copies (Mara M)
If SwiftBar's PluginDirectory is set to a non-existent or non-writable path, `cp` fails AFTER `bin/`+`config/` copies have already happened.
**Fix:** Preflight `[[ -d "$PLUGIN_LIVE_DIR" && -w "$PLUGIN_LIVE_DIR" ]]` before any copy; mkdir/prompt if needed.

### B.4 — `etc/local.conf.example:20` vs plugin parser — FLAP_WINDOW=0 accepted despite "positive integer" claim (Mara M)
Parser regex `^[0-9]+$` accepts 0; `age -lt 0` is always false → flap detection silently disabled.
**Fix:** Tighten regex to `^[1-9][0-9]*$` or document `0=disable` semantics.

### B.5 — `README.md:151-153` — Troubleshooting hardcodes managed path (Mara M)
First troubleshooting step assumes plugin lives in `~/.local/share/agents-monitor/swiftbar/`; for users with custom PluginDirectory it lives elsewhere. README guidance gives false-positive "broken install" diagnosis.
**Fix:** First step = `defaults read com.ameba.SwiftBar PluginDirectory` and `cat ~/.local/share/agents-monitor/.plugin-installed-at`, then check the actual path.

### B.6 — `swiftbar/agents-monitor.30s.sh:363/370` — HELPER env-overridable in single-quoted shell snippets (Hermes M)
"Restart all" actions embed `${HELPER}` inside `bash="$HELPER"` → if `$AGENTS_MONITOR_HELPER` is set to a path containing `'`, breaks shell quoting and enables injection. Direct evaluation of an env-controlled string in a clickable action surface.
**Fix:** Validate `AGENTS_MONITOR_HELPER` matches `^/[A-Za-z0-9._/-]+$` and is an executable file at script start; reject otherwise.

### B.7 — `install.sh:73` — Installer doesn't reject group/world-writable parent dirs (Hermes M)
Installs `launchctl-user` (clickable from menu) into `~/.local/bin/` without checking if parent dir is `chmod 0755`-strict. Local multi-user tampering can replace the helper between install and click.
**Fix:** Check ownership (`stat -f '%u' ~/.local/bin == $UID`), check perms (no `g+w` or `o+w`), refuse unsafe parents with clear error.

### B.8 — `README.md:143` — AppleScript safety overclaim (Hermes M, msg 4574)
Notification body has newline/control-char failure mode despite `\\` and `\"` escaping. Multi-line `display notification` strings can still confuse the AppleScript parser.
**Fix:** Switch to argv passing: `osascript -e 'on run argv' -e 'display notification (item 1 of argv) ...' -- "$msg"`. Eliminates string interpolation entirely.

### B.9 — Awk parsing of `launchctl print` is brittle (Case WEAKEST POINT)
`pid = X` / `last exit code = Y` patterns not formally contracted by Apple. One format change → silent misclassification.
**Fix:** Emit env-gated debug breadcrumb (`AGENTS_MONITOR_DEBUG=1`) when a known-loaded service yields neither field. Surfaces format drift before it becomes outage.

---

## C. SUGGESTIONS (worth applying; not blockers)

### C.1 — `install.sh:121-127` — Copy plugin into EXISTING_DIR is invasive (Mara S, Hermes echoed)
Owns user space outside our managed scope.
**Alternative:** Always install plugin into managed `$SHARE_DIR/swiftbar/`, place a SYMLINK in EXISTING_DIR pointing to the managed file. One source of truth, clean updates, clean uninstall.

### C.2 — `bin/launchctl-user:62` — `launchctl bootstrap` fails on EALREADY (Case S)
With `set -euo pipefail`, exit code 5/17 from bootstrap aborts.
**Fix:** Detect EALREADY, run bootout, retry once.

### C.3 — `bin/agents-monitor-uninstall:20` — `.plugin-installed-at` consumed unsafely (Hermes S)
Mutable pointer file passed to `rm -f` without validation.
**Fix:** Require absolute path, basename = `agents-monitor.30s.sh`, parent = current/recorded SwiftBar PluginDirectory. Refuse otherwise.

### C.4 — Supply-chain doc gap (Hermes S, msg 4574)
README tells strangers `git clone && ./install.sh` without explicit "read before running" or release-tag pin recommendation. install.sh has real side effects (brew install, defaults write).
**Fix:** Add Security section subhead "Before running install.sh", recommend `git checkout v0.1.0` instead of `main`, list explicit side effects.

### C.5 — Helper `restart-many label...` subcommand (Hermes S, msg 4574)
"Restart all" currently composes shell text. Cleanest pattern: extend helper with batch subcommand, call via `bash="$HELPER" param0="restart-many" param1=label1 ...`.
**Fix:** Add `restart-many` to launchctl-user; refactor "Restart all" to use it.

### C.6 — `README.md` too monolithic (Mara S)
At 14 KB, the publication README has security, troubleshooting, customization, architecture, philosophy all inline.
**Fix:** Split into `docs/CONFIGURATION.md`, `docs/SECURITY.md`. Keep README as "quick start + pointers".

---

## D. NITS (deferred)

### D.1 — Tilde `~user/foo` form in uninstall (Case N)
`defaults read` could return `~user/Plugins`; current expansion only handles `~/foo`.

### D.2 — Two `launchctl` calls per service per refresh (Case S, accepted)
Trade-off documented; format coupling concern is the real risk and is addressed by B.9.

---

## E. POSITIVE CALL-OUTS (Hermes — to advertise more)

- No `sudo` anywhere
- User-domain only (`gui/$UID`)
- `local.conf` parsed as data not code
- Service/brew labels filtered before shell-rendered actions

---

## Summary

- **Total substantive findings:** 17 (after deduping 2 convergent pairs)
- **Convergent (highest confidence):** 2 — A.1, A.2
- **Must-fix (blocking publish):** 9 — B.1 through B.9
- **Suggestions (high value, defer-able):** 6 — C.1 through C.6
- **Nits (deferred):** 2 — D.1, D.2

**Process notes:**
- Hermes had Codex/gpt-5.5 model failures during Round 1 but eventually delivered the strongest security review (msg 4570 + 4574).
- Case Gibson initially attempted to claim coordinator role; corrected by Fabio (msg 4538), Case retracted (msg 4557), proceeded as reviewer.
- Round 2 (rebuttal) skipped per Fabio's direction — sufficient quality from Round 1.
