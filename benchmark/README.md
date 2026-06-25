# benchmark/

Stored benchmark results + the raw data needed to reproduce them. Each subdir is
one dated run; the harness and method live in `scripts/bench/` and
`docs/PERFORMANCE.md`.

Raw captures here are secret-free: device runs use the real (properly-signed)
account with no env hooks, and only `SONAR_BENCH` marker lines are kept (phase
markers + `groups=` / `woke=` / `notif=` — no keys). Never commit `nsec`/`npub`,
`SONAR_BENCH_NSEC` env dumps, or Breez keys here.

## Runs

- [`cold-start-sync-2026-06-24/`](cold-start-sync-2026-06-24/RESULTS.md) —
  cold-start → Marmot relay-sync. **Production finding:** on the real account
  (iPhone 14 Pro Max, 24 groups) cold → synced is ~52–66 s, of which ~57 s is two
  blocking relay publishes (`publishKeyPackage` + `publishProfile`) on the
  cold-start critical path — not the sync (`drainPending` ~1.7 s).
