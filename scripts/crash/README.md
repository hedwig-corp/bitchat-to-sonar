# Crash report analysis

Symbolicate + summarize Apple crash reports for the Sonar iOS app, fully local.

## TL;DR

```sh
# Drop exported .ips/.crash files into ./crashes/ then:
python3 scripts/crash/symbolicate.py crashes

# Or point at a specific file / folder:
python3 scripts/crash/symbolicate.py ~/Downloads/Sonar-2026-06-25.ips
```

It prints app/build/OS, the exception, the crashed thread with symbolicated
app frames (with source file:line), and the **likely crash site**.

## Where to get the report

- **Xcode → Window → Organizer → Crashes** → right‑click a crash →
  *Show in Finder* (or *Export*). Often already symbolicated there.
- **App Store Connect** → app → *TestFlight* / *App Analytics → Metrics →
  Crashes* → download the `.ips`.
- The same crashes are also grouped in **Firebase Crashlytics** (the app links
  Crashlytics and uploads dSYMs), already symbolicated.

## How symbolication is resolved

For each app‑owned image (`Sonar`, `SonarNotificationService`,
`bitchatShareExtension`) the script finds the matching `.dSYM` by UUID:

1. Spotlight: `mdfind "com_apple_xcode_dsym_uuids == <UUID>"`
2. Fallback: scans `~/Library/Developer/Xcode/Archives` and `DerivedData`,
   matching UUIDs with `dwarfdump`.

Then resolves frames with `atos -o <DWARF> -arch arm64 -l <imageBase> <addr>`.

If a frame shows `NO dSYM`, the build that produced that crash wasn't archived
on this machine — grab its `.xcarchive` (it has the matching dSYM) or the dSYM
zip from App Store Connect (*Activity → Builds → download dSYM*) and re‑run.

## Privacy

Raw crash reports can contain device/user data and are **gitignored**
(`crashes/.gitignore`). Don't commit them.
