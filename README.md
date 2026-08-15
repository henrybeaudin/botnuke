# app-purge

Thoroughly remove a macOS application and the files it leaves behind.

Dragging an app to the Trash removes the bundle and nothing else. Support
directories, caches, preferences, saved state, login items, launch agents, and
any background helper processes stay on disk — sometimes still running, and
sometimes ready to restore themselves the moment the app is reinstalled.

`app-purge.sh` finds those, stops what's running, and moves everything into a
dated quarantine folder.

**Nothing is ever deleted, and nothing is touched without `--apply`.**

## Usage

```sh
./app-purge.sh "Some App"            # dry run — report only (default)
./app-purge.sh --apply "Some App"    # quarantine for real
```

The name should match the bundle in `/Applications` without the `.app` suffix.
Quote it if it contains spaces.

### Options

| Flag | Effect |
|---|---|
| `--apply` | Actually move files. Without it, the script only reports. |
| `-y`, `--yes` | Skip the confirmation prompt. |
| `--extra-pattern RE` | Extra regex for helper processes named differently from the app. |
| `-h`, `--help` | Usage. |
| `--version` | Version. |

### Example

An Electron app that also runs a background daemon under an unrelated name:

```sh
./app-purge.sh --apply --extra-pattern 'helper-daemon' "Some App"
```

## What it does

1. Lists matching processes, excluding itself and its own children.
2. Reads the bundle ID, version, and code signature from `Info.plist`.
3. Finds and unloads LaunchAgents / LaunchDaemons referencing the app.
4. Removes login items.
5. Asks the app to quit via AppleScript, then escalates to `TERM`, then `KILL`.
6. Quarantines the `.app` bundle.
7. Quarantines support files across `~/Library`: `Application Support`,
   `Caches`, `Logs`, `Preferences`, `HTTPStorages`, `WebKit`,
   `Saved Application State`, `Containers`, `Group Containers`,
   `Application Scripts`, `CrashReporter`, `Cookies`, `Autosave Information`
   — plus dotfile config dirs and anything keyed by bundle ID.
8. Exports and clears the app's `defaults` domain (the export is kept).
9. Reports what it deliberately did not touch.
10. Verifies, and tells you what's left.

## What it deliberately won't do

Reported, never acted on:

- **Files needing `sudo`** — printed as a command for you to review and run.
- **Keychain items** — listed; remove them in Keychain Access.
- **TCC privacy grants** (Screen Recording, Accessibility, Input Monitoring,
  Full Disk Access) — these survive deletion and silently reapply if the app is
  ever reinstalled. Check System Settings → Privacy & Security.
- **Server-side credentials.** Deleting local files does not revoke an API
  token or session. If the app held one, revoke it in the vendor's account
  settings.
- **Near misses** — files matching the app's first word but not its full name
  are listed separately and left alone, so a stray `Some` directory next to
  `Some App` gets surfaced without being assumed.

## Safety model

- **Dry run by default.** `--apply` is required to change anything.
- **Move, never delete.** Everything lands in `~/app-purge-quarantine-<stamp>/`,
  mirroring its original path, with a `report.txt`. Inspect it, restore
  anything you want back, delete the folder when satisfied.
- **Refuses `sudo`.** It resolves `$HOME`; running it elevated would either
  target the wrong home directory or leave root-owned files in yours.
- **Won't kill itself.** Self-matching is a real hazard here — a script whose
  own command line contains the search term will happily `pkill` its own
  process group. Matching PIDs are filtered against `$$`, `$PPID`, the script
  name, and the quarantine path, and the quarantine directory is named to avoid
  containing the app slug.
- **Word-boundary matching.** `"Some App"` becomes `some[ _-]?app`, matching
  `Some App`, `SomeApp`, `some-app`, and `some_app`, but not `something`.
- **No silent failures.** Portable `find` only — no `-E` / `-iregex`, which vary
  between BSD and GNU and return empty rather than erroring when unsupported.
  A file search that finds nothing because the syntax was rejected is worse
  than one that crashes.

## Requirements

macOS and `bash`. The script re-executes itself under `/bin/bash` on startup,
so it works even when invoked in a way that ignores the shebang.

## Caveats

Matching is name-based. An app whose support files are named nothing like the
app — or an app with a very generic name — will need the dry run reviewed
carefully before you apply. That is what the dry run is for.

Run it once more in dry-run mode after a reboot to confirm nothing came back.

## License

MIT
