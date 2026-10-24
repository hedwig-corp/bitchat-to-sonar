#!/usr/bin/env python3
"""Compare a freshly generated (normalized) vector file with the committed one.

Prints added / removed / changed cases by name and kind and exits 1 on any
difference. A changed `expected` means the upstream codec changed its bytes
for an input it used to encode differently — a wire-format event that needs a
decision in core/bitchat-protocol/SPEC.md, not a test edit.

Usage: diff.py <committed.json> <fresh.json>
"""
import json
import sys


def index(path):
    d = json.load(open(path))
    # Keyed by (kind, name): names repeat across kinds (the Android dump uses
    # the same payload names for should_compress and compress).
    cases = {(c["kind"], c["name"]): c for c in d["cases"]}
    return d, cases


def main(committed, fresh):
    cd, cc = index(committed)
    fd, fc = index(fresh)
    added = sorted(set(fc) - set(cc))
    removed = sorted(set(cc) - set(fc))
    changed = sorted(
        n for n in set(cc) & set(fc)
        if cc[n]["expected"] != fc[n]["expected"] or cc[n]["input"] != fc[n]["input"]
    )
    for k, n in added:
        print(f"ADDED    {k:24} {n}")
    for k, n in removed:
        print(f"REMOVED  {k:24} {n}")
    for key in changed:
        c, f = cc[key], fc[key]
        what = "input" if c["input"] != f["input"] else "expected"
        print(f"CHANGED  {key[0]:24} {key[1]} ({what})")
        for k in sorted(set(c[what]) | set(f[what])):
            a, b = c[what].get(k), f[what].get(k)
            if a != b:
                sa, sb = json.dumps(a), json.dumps(b)
                print(f"           {k}: {sa[:70]}{'…' if len(sa) > 70 else ''}")
                print(f"           {' ' * len(k)}  -> {sb[:70]}{'…' if len(sb) > 70 else ''}")
    if cd.get("source") != fd.get("source"):
        print(f"SOURCE   {cd.get('source')} -> {fd.get('source')}")
    if added or removed or changed:
        print(f"\n{len(added)} added, {len(removed)} removed, {len(changed)} changed "
              f"(of {len(cc)} committed cases)")
        return 1
    print(f"OK       {len(cc)} cases identical")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2]))
