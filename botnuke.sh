#!/bin/bash
#
# botnuke.sh — thoroughly remove a macOS application and its leftovers
#
# Deleting an app from /Applications leaves its support files, caches,
# preferences, login items, and any background helpers behind. This finds
# those, stops what's running, and MOVES everything into a dated quarantine
# folder so the removal is reversible.
#
# Nothing is ever deleted. Nothing is touched without --apply.
#
#   ./botnuke.sh "Some App"            # dry run: report only (default)
#   ./botnuke.sh --apply "Some App"    # actually quarantine
#
# Operates on the current user only ($HOME). Run WITHOUT sudo.
#
# Requires: macOS, bash. Tested on Sonoma and Sequoia.
# License: MIT
#

# --- guarantee real bash, regardless of how we were invoked ---------------
if [ -z "${_BOTNUKE_BASH:-}" ]; then
  _BOTNUKE_BASH=1
  export _BOTNUKE_BASH
  exec /bin/bash "$0" "$@"
fi
# --------------------------------------------------------------------------

set -uo pipefail

VERSION="1.0.0"
SELF="$(basename "$0")"

APPLY=0
ASSUME_YES=0
EXTRA_PATTERN=""
APP_NAME=""

usage() {
  cat <<'HELPEOF' | sed "s/{{V}}/$VERSION/; s/{{S}}/$SELF/g"
botnuke.sh {{V}} — remove a macOS app and everything it left behind

USAGE
  {{S}} [options] "App Name"

  "App Name" should match the bundle as it appears in /Applications,
  without the .app suffix. Quote it if it contains spaces.

OPTIONS
  --apply              Actually quarantine files. Without this, the script
                       only reports what it would do and changes nothing.
  -y, --yes            Skip the confirmation prompt (implies non-interactive).
  --extra-pattern RE   Additional case-insensitive regex for finding related
                       processes — useful when an app spawns helpers under a
                       different name (e.g. a background exec daemon).
  -h, --help           Show this help.
  --version            Print version.

WHAT IT COVERS
  running processes and Electron/helper children, LaunchAgents and
  LaunchDaemons, login items, the .app bundle, ~/Library/Application Support,
  Caches, Preferences, HTTPStorages, WebKit, Saved Application State,
  Containers, Group Containers, Application Scripts, CrashReporter,
  and the app's cfprefs domain.

WHAT IT DEFERS TO YOU
  system-level files needing sudo, Keychain items, TCC privacy grants
  (Screen Recording, Accessibility, Full Disk Access), and any account or
  credential held on the vendor's servers. These are reported, not touched.

EXAMPLES
  {{S}} "Some App"
  {{S}} --apply "Some App"
  {{S}} --apply --extra-pattern 'helper-daemon' "Some App"

HELPEOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)          APPLY=1; shift ;;
    -y|--yes)         ASSUME_YES=1; shift ;;
    --extra-pattern)  EXTRA_PATTERN="${2:-}"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    --version)        echo "$VERSION"; exit 0 ;;
    -*)               echo "unknown option: $1" >&2; echo; usage >&2; exit 2 ;;
    *)
      if [ -n "$APP_NAME" ]; then
        echo "error: more than one app name given ('$APP_NAME' and '$1')" >&2
        echo "hint: quote names containing spaces" >&2
        exit 2
      fi
      APP_NAME="$1"; shift ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || { echo "error: macOS only" >&2; exit 1; }
[ -n "$APP_NAME" ] || { usage >&2; exit 2; }

if [ "$(id -u)" = "0" ]; then
  cat >&2 <<'ROOT'
error: do not run this with sudo.

It resolves $HOME and operates on the current user's Library. Under sudo you
would either act on the wrong home directory or leave root-owned files in
yours. Run it as yourself; anything genuinely needing elevation is printed
as a command for you to review and run.
ROOT
  exit 1
fi

############################################################
# Derive match patterns from the app name.
#
# "Some App" has to match Some App / SomeApp / some-app / some_app, because
# apps are inconsistent about how they name processes, bundle ids, and
# support directories. Word boundaries become [ _-]? and matching is
# case-insensitive throughout.
############################################################
slug_regex() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/ /g; s/^ +//; s/ +$//' \
    | sed -E 's/ +/[ _-]?/g'
}

NAME_RE="$(slug_regex "$APP_NAME")"
[ -n "$NAME_RE" ] || { echo "error: app name has no usable characters" >&2; exit 2; }

FIRST_WORD="$(printf '%s' "$APP_NAME" | tr '[:upper:]' '[:lower:]' \
              | sed -E 's/[^a-z0-9]+/ /g' | awk '{print $1}')"

PROC_RE="$NAME_RE"
[ -n "$EXTRA_PATTERN" ] && PROC_RE="$NAME_RE|$EXTRA_PATTERN"

APP_PATH=""
for cand in "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"; do
  [ -d "$cand" ] && { APP_PATH="$cand"; break; }
done

STAMP="$(date +%Y%m%d-%H%M%S)"
Q="$HOME/botnuke-quarantine-$STAMP"       # deliberately free of the app slug,
                                          # so the path can't match PROC_RE
LOG=""
if [ "$APPLY" = "1" ]; then
  mkdir -p "$Q" || { echo "error: cannot create $Q" >&2; exit 1; }
  LOG="$Q/report.txt"
  exec > >(tee -a "$LOG") 2>&1
fi

MOVED=0
SKIPPED=0
FAILED=0

say()  { printf '%s\n' "$*"; }
head2() { printf '\n### %s\n' "$*"; }

# Matching PIDs, excluding this script and anything it spawned. Without this
# the script matches its own command line and kills itself.
live_pids() {
  local p cmd
  for p in $(pgrep -fi "$PROC_RE" 2>/dev/null); do
    [ "$p" = "$$" ] && continue
    [ "$p" = "$PPID" ] && continue
    cmd="$(ps -o command= -p "$p" 2>/dev/null)"
    [ -z "$cmd" ] && continue
    case "$cmd" in
      *"$SELF"*) continue ;;
      *"$Q"*)    continue ;;
    esac
    printf '%s ' "$p"
  done
}

# quarantine <path> <bucket>
quarantine() {
  local src="$1" bucket="${2:-misc}" dest rel
  [ -e "$src" ] || return 0
  if [ "$APPLY" != "1" ]; then
    say "  would move   $src"
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi
  case "$src" in
    "$HOME"/*) rel="${src#$HOME/}" ;;
    *)         rel="${src#/}" ;;
  esac
  dest="$Q/$bucket/$(dirname "$rel")"
  mkdir -p "$dest"
  if mv "$src" "$dest/" 2>/dev/null; then
    say "  moved        $src"
    MOVED=$((MOVED + 1))
  else
    say "  FAILED       $src"
    say "               sudo mv \"$src\" \"$dest/\""
    FAILED=$((FAILED + 1))
  fi
}

# Coarse filter with -iname on the first word (portable), then refine against
# the full regex. Avoids find -E / -iregex, which vary between BSD and GNU and
# fail *silently* when unsupported.
find_hits() {   # find_hits <root> <maxdepth>
  [ -d "$1" ] || return 0
  find "$1" -maxdepth "$2" -iname "*${FIRST_WORD}*" -prune -print 2>/dev/null \
    | grep -Ei "$NAME_RE"
}

# Same coarse filter, but everything the strict regex rejected — reported, not
# acted on, so a stray "Some" directory next to "Some App" still gets surfaced.
find_near_misses() {
  [ -d "$1" ] || return 0
  find "$1" -maxdepth "$2" -iname "*${FIRST_WORD}*" -prune -print 2>/dev/null \
    | grep -Eiv "$NAME_RE"
}

############################################################
say "=================================================="
say " botnuke $VERSION"
say " target:     $APP_NAME"
say " bundle:     ${APP_PATH:-not found in /Applications or ~/Applications}"
say " match:      $PROC_RE"
if [ "$APPLY" = "1" ]; then
  say " mode:       APPLY — files will be moved"
  say " quarantine: $Q"
else
  say " mode:       DRY RUN — nothing will be changed"
  say "             re-run with --apply to act on this"
fi
say "=================================================="

############################################################
head2 "1. Running processes"
PIDS="$(live_pids)"
if [ -n "${PIDS// /}" ]; then
  ps -o pid,ppid,user,command -p ${PIDS} 2>/dev/null | cut -c1-160
else
  say "  none"
fi

############################################################
head2 "2. Bundle identity"
BUNDLE_ID=""
if [ -n "$APP_PATH" ]; then
  BUNDLE_ID="$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleIdentifier 2>/dev/null)"
  say "  path:       $APP_PATH"
  say "  bundle id:  ${BUNDLE_ID:-unknown}"
  say "  version:    $(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo unknown)"
  say "  signed by:"
  codesign -dv "$APP_PATH" 2>&1 | grep -Ei 'authority|identifier|teamid' | sed 's/^/    /' || say "    (unsigned or unreadable)"
else
  say "  no .app bundle found — continuing with leftover files"
fi

############################################################
head2 "3. Launch agents and daemons"
LAUNCH_HITS=""
for dir in "$HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons; do
  [ -d "$dir" ] || continue
  hits="$(grep -rlEi "$NAME_RE" "$dir" 2>/dev/null)"
  [ -n "$hits" ] && LAUNCH_HITS="$LAUNCH_HITS$hits"$'\n'
done
if [ -n "${LAUNCH_HITS//[$'\n' ]/}" ]; then
  while IFS= read -r plist; do
    [ -n "$plist" ] || continue
    say "  $plist"
    if [ "$APPLY" = "1" ]; then
      label="$(basename "$plist" .plist)"
      launchctl bootout "gui/$(id -u)/$label" 2>/dev/null && say "    unloaded"
    fi
    if [ -w "$plist" ]; then
      quarantine "$plist" "launch"
    else
      say "    needs elevation: sudo rm \"$plist\""
    fi
  done <<< "$LAUNCH_HITS"
else
  say "  none"
fi

############################################################
head2 "4. Login items"
LI="$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null \
      | tr ',' '\n' | sed 's/^ *//' | grep -Ei "$NAME_RE")"
if [ -n "$LI" ]; then
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    if [ "$APPLY" = "1" ]; then
      if osascript -e "tell application \"System Events\" to delete login item \"$item\"" 2>/dev/null; then
        say "  removed      $item"
      else
        say "  FAILED       $item — remove in System Settings > General > Login Items"
      fi
    else
      say "  would remove $item"
    fi
  done <<< "$LI"
else
  say "  none"
fi

############################################################
head2 "5. Confirmation"
if [ "$APPLY" != "1" ]; then
  say "  dry run — skipping"
elif [ "$ASSUME_YES" = "1" ]; then
  say "  --yes given, proceeding"
elif [ -e /dev/tty ]; then
  printf '  Quit %s and quarantine the files above and below? [y/N] ' "$APP_NAME"
  read -r ans < /dev/tty
  case "$ans" in
    y|Y) say "  proceeding" ;;
    *)   say "  aborted — nothing was changed"; exit 0 ;;
  esac
else
  say "  no tty and no --yes — aborting"; exit 1
fi

############################################################
head2 "6. Stopping the app"
if [ "$APPLY" != "1" ]; then
  say "  would quit and terminate: ${PIDS:-none}"
else
  if [ -n "$APP_PATH" ]; then
    osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null && say "  asked it to quit"
    sleep 4
  fi
  PIDS="$(live_pids)"
  if [ -n "${PIDS// /}" ]; then
    say "  sending TERM"
    kill ${PIDS} 2>/dev/null
    sleep 3
    PIDS="$(live_pids)"
    if [ -n "${PIDS// /}" ]; then
      say "  sending KILL"
      kill -9 ${PIDS} 2>/dev/null
      sleep 2
    fi
  fi
  PIDS="$(live_pids)"
  if [ -n "${PIDS// /}" ]; then
    say "  STILL RUNNING — something is respawning it:"
    ps -o pid,ppid,command -p ${PIDS} 2>/dev/null | cut -c1-160
  else
    say "  stopped"
  fi
fi

############################################################
head2 "7. Application bundle"
[ -n "$APP_PATH" ] && quarantine "$APP_PATH" "app" || say "  none"

############################################################
head2 "8. Support files"
for sub in "Application Support" "Caches" "Logs" "Preferences" "HTTPStorages" "WebKit" \
           "Saved Application State" "Containers" "Group Containers" \
           "Application Scripts" "Application Support/CrashReporter" \
           "Cookies" "Autosave Information"; do
  while IFS= read -r hit; do
    [ -n "$hit" ] && quarantine "$hit" "library"
  done <<< "$(find_hits "$HOME/Library/$sub" 2)"
done

# Dotfile config directories
for d in "$HOME/.$(printf '%s' "$APP_NAME" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')" \
         "$HOME/.config/$(printf '%s' "$APP_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"; do
  quarantine "$d" "config"
done

# Bundle-id-keyed files and the cfprefs domain
if [ -n "$BUNDLE_ID" ]; then
  while IFS= read -r hit; do
    [ -n "$hit" ] && quarantine "$hit" "library"
  done <<< "$(find "$HOME/Library" -maxdepth 3 -name "*${BUNDLE_ID}*" -prune -print 2>/dev/null)"
  if [ "$APPLY" = "1" ]; then
    defaults export "$BUNDLE_ID" "$Q/defaults-$BUNDLE_ID.plist" 2>/dev/null \
      && defaults delete "$BUNDLE_ID" 2>/dev/null \
      && say "  cleared defaults domain $BUNDLE_ID (backed up in quarantine)"
  else
    say "  would clear defaults domain $BUNDLE_ID"
  fi
fi

############################################################
head2 "9. Not handled — review these yourself"
say "-- similarly-named files that did NOT match strictly:"
NEAR=""
for sub in "Application Support" "Caches" "Preferences" "Logs" "Containers"; do
  n="$(find_near_misses "$HOME/Library/$sub" 2)"
  [ -n "$n" ] && NEAR="$NEAR$n"$'\n'
done
if [ -n "${NEAR//[$'\n' ]/}" ]; then
  printf '%s' "$NEAR" | sed '/^$/d; s/^/   /'
  say "   (left alone — inspect and remove by hand if they belong to this app)"
else
  say "   none"
fi
say "-- launchd jobs still registered:"
launchctl list 2>/dev/null | grep -Ei "$NAME_RE" || say "   none"
say "-- keychain items (remove via Keychain Access):"
security dump-keychain 2>/dev/null | grep -Ei "$NAME_RE" | head -10 || say "   none found"
say "-- privacy grants:"
say "   System Settings > Privacy & Security — check Screen Recording,"
say "   Accessibility, Input Monitoring, and Full Disk Access for an entry."
say "   These survive deletion and silently reapply on reinstall."
say "-- server-side state:"
say "   Local removal does not revoke credentials. If the app held an API"
say "   token or session, revoke it in the vendor's account settings."

############################################################
head2 "10. Verification"
if [ "$APPLY" != "1" ]; then
  say "  dry run — $SKIPPED item(s) would be quarantined"
  say ""
  say "  Re-run with --apply to proceed:"
  say "    $0 --apply \"$APP_NAME\""
else
  sleep 1
  P="$(live_pids)"
  [ -z "${P// /}" ] && say "  [ok]   no processes running" || say "  [FAIL] still running: $P"
  if [ -n "$APP_PATH" ]; then
    [ -e "$APP_PATH" ] && say "  [FAIL] bundle remains" || say "  [ok]   bundle removed"
  fi
  R="$(find_hits "$HOME/Library/Application Support" 1)"
  [ -z "$R" ] && say "  [ok]   no support files remain" || say "  [warn] remaining: $R"
  say ""
  say "  moved: $MOVED    failed: $FAILED"
  say "  quarantine: $Q"
  say "  report:     $LOG"
  say ""
  say "  Reboot, re-run in dry-run mode to confirm nothing returned,"
  say "  then delete the quarantine folder when you're satisfied."
fi
say ""
