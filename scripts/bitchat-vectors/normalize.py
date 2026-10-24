#!/usr/bin/env python3
"""Normalize a raw vector dump into the committed form.

The generators (core/bitchat-protocol/vectors/generators/) emit every case
verbatim; the committed files drop the two 70000-byte stress cases (the crate
pins that shape in its own tests) and write hex strings that are one byte
repeated >= 1024 times as "repeat:xx*N". Normalizing both sides the same way
is what lets regenerate.sh diff a fresh dump against the committed file.

Usage: normalize.py <raw.json> <out.json>
"""
import json
import re
import sys

HEX = re.compile(r"^[0-9a-f]*$")
DROP = {
    "v2_type22_70000_recipient_signed",
    "8_v2_type_0x22_70000_bytes_recipient_signature",
}
NOTE = (
    "Trimmed for the repository: the two 70000-byte v2 file-transfer cases were "
    "dropped (the crate pins that shape in its own tests) and hex strings that are "
    "one byte repeated >= 1024 times are written as \"repeat:xx*N\". Regenerate with "
    "scripts/bitchat-vectors/regenerate.sh."
)


def compact(o):
    if isinstance(o, str) and len(o) >= 2048 and len(o) % 2 == 0 and HEX.match(o):
        b = o[:2]
        if o == b * (len(o) // 2):
            return f"repeat:{b}*{len(o) // 2}"
        return o
    if isinstance(o, dict):
        return {k: compact(v) for k, v in o.items()}
    if isinstance(o, list):
        return [compact(x) for x in o]
    return o


def main(src, dst):
    d = json.load(open(src))
    d["cases"] = [compact(c) for c in d["cases"] if c["name"] not in DROP]
    d["note"] = NOTE
    with open(dst, "w") as f:
        json.dump(d, f, indent=1, sort_keys=True)
        f.write("\n")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
