#!/usr/bin/env python3
"""Cross-replay of the bitchat vectors: each reference codec against the
other reference codec's bytes.

`regenerate.sh` proves each upstream codec still produces its own committed
vectors; `tests/vectors.rs` proves the Rust crate agrees with both. Neither
shows that stock bitchat iOS and stock bitchat-android agree with EACH OTHER.
This script does, in three steps:

  ops      <vectors.json> <ops.json>
      Rewrite one platform's vector file into a platform-neutral list of
      operations ("encode this packet", "decode these bytes", "rebuild the
      signature preimage of the decoded packet", ...), each carrying the
      SOURCE codec's output as the expected value. 64-bit integers are
      decimal strings so they survive every JSON parser.

  (the observers)
      `core/bitchat-protocol/vectors/cross/SonarCrossObserver.swift` and
      `SonarCrossObserverTest.kt` run inside the upstream checkouts (installed
      by `cross-replay.sh`), feed every operation to the real codec and write
      what it returned. They compare nothing; all judgement is here.

  compare  --ops ops.json --results results.json --source S --target T
           [--ledger ledger.json] [--report out.json]
      Compare the target codec's outputs with the source codec's. Every
      mismatch must be explained by an entry in the ledger
      (`vectors/cross/ledger.json`, keyed by source, target, op, field and a
      case-name regex); every ledger entry for this direction must still
      match at least one mismatch, so a divergence that upstream fixes turns
      into a visible "stale entry" failure instead of a silently obsolete
      note. Self-replay (S == T) must match exactly with no ledger at all,
      which is what proves the harness itself is sound.

Exit status of compare: 0 all explained and no stale entries, 1 otherwise.
"""
import argparse
import json
import re
import sys

U64 = ("caps", "raw", "timestamp", "size")


def big(v):
    # bitchat-android records capabilities in a signed Long (-1 for all bits
    # set); the wire value is the unsigned 64-bit pattern.
    return None if v is None else str(int(v) & 0xFFFF_FFFF_FFFF_FFFF)


def expand(h):
    if isinstance(h, str) and h.startswith("repeat:"):
        b, n = h[len("repeat:"):].split("*")
        return b * int(n)
    return h


def unhex(h):
    return bytes.fromhex(expand(h))


# --------------------------------------------------------------------------
# ops: source schema -> neutral operations
# --------------------------------------------------------------------------

class Ops:
    def __init__(self, source):
        self.source = source
        self.ops = []

    def add(self, case, suffix, op, inp, exp):
        exp = {k: v for k, v in exp.items() if v is not _ABSENT}
        # Optional announce fields only Swift models: expect them only when the
        # source actually carried a value, so a codec without the field is
        # reported as "not modeled" exactly where it would drop data.
        for k in ("neighbors", "geohash"):
            if k in exp and exp[k] is None:
                del exp[k]
        if not exp:
            return
        self.ops.append({"id": f"{case['kind']}:{case['name']}{suffix}", "case": case["name"],
                         "kind": case["kind"], "op": op, "in": inp, "exp": exp})


_ABSENT = object()


def get(d, k):
    return d[k] if k in d else _ABSENT


def packet_fields(i):
    return {"version": i["version"], "type": i["type"], "ttl": i["ttl"],
            "timestamp": big(i["timestamp"]), "sender": i["sender_id"],
            "recipient": i.get("recipient_id"), "route": i.get("route"),
            "payload": i["payload"], "signature": i.get("signature"),
            "is_rsr": i.get("is_rsr", False)}


def decoded_expectations(fields, e, ios):
    """What decoding the source's own frame must yield, from the source's record."""
    sig = e.get("decoded_signature", fields["signature"])
    return {
        "decodes": True,
        "version": fields["version"], "type": fields["type"],
        "ttl": e.get("decoded_ttl", fields["ttl"]),
        "timestamp": fields["timestamp"],
        "sender": e.get("decoded_sender_id", fields["sender"]),
        "recipient": e.get("decoded_recipient_id", fields["recipient"]),
        "route": e.get("decoded_route", fields["route"]),
        "payload": e.get("decoded_payload", fields["payload"]),
        "signature": sig,
        # The verify path: the preimage rebuilt from the DECODED packet must be
        # the one the originator signed.
        "preimage": e.get("signing_preimage", _ABSENT),
    }


def ops_packet_encode(o, c):
    i, e = c["input"], c["expected"]
    f = packet_fields(i)
    o.add(c, "", "packet_encode", f, {"padded": e.get("padded"), "unpadded": e.get("unpadded"),
                                      "preimage": get(e, "signing_preimage")})
    if e.get("padded") is None:
        return
    dec = decoded_expectations(f, e, o.source == "ios")
    # Relay path: re-encoding the decoded packet reproduces the frame.
    o.add(c, "#decode_padded", "packet_decode", {"bytes": e["padded"]},
          dict(dec, reencoded_unpadded=e["unpadded"], reencoded_padded=e["padded"]))
    o.add(c, "#decode_unpadded", "packet_decode", {"bytes": e["unpadded"]},
          dict(dec, reencoded_unpadded=e["unpadded"]))


def ops_packet_reencode(o, c, by_unpadded_len):
    """bitchat-android's decode-then-re-encode cases. The foreign-stream case
    has no recorded preimage; it is derived from the packet_encode case whose
    frame differs from it only inside the DEFLATE stream, by applying the same
    byte substitution (the preimage keeps the payload at the same offsets: the
    signature it drops sits after the payload)."""
    i, e = c["input"], c["expected"]
    exp = {"decodes": True}
    if e.get("equals_original_unpadded"):
        exp["reencoded_unpadded"] = e["reencoded"]
    if e.get("equals_original_padded"):
        exp["reencoded_padded"] = i["padded"]
    frame = unhex(e["reencoded"]) if e.get("equals_original_unpadded") else None
    if frame is not None:
        for ref_unpadded, ref_preimage in by_unpadded_len.get(len(frame), []):
            ref = unhex(ref_unpadded)
            diff = [k for k in range(len(frame)) if frame[k] != ref[k]]
            wire = unhex(e["decoded_wire_bytes"])
            start = bytes(frame).find(wire)
            if ref_preimage and start >= 0 and all(start <= k < start + len(wire) for k in diff):
                pre = bytearray(unhex(ref_preimage))
                for k in diff:
                    pre[k] = frame[k]
                exp["preimage"] = pre.hex()
                break
    o.add(c, "", "packet_decode", {"bytes": i["padded"]}, exp)


def build_ops(path):
    d = json.load(open(path))
    src = "ios" if "permissionlesstech/bitchat@" in d.get("source", "") else "android"
    o = Ops(src)
    by_len = {}
    for c in d["cases"]:
        if c["kind"] == "packet_encode" and c["expected"].get("unpadded"):
            by_len.setdefault(len(unhex(c["expected"]["unpadded"])), []).append(
                (c["expected"]["unpadded"], c["expected"].get("signing_preimage")))
    for c in d["cases"]:
        k, i, e = c["kind"], c["input"], c["expected"]
        if k == "should_compress":
            o.add(c, "", "compress_decision", {"payload": i["payload"]}, {"result": e["result"]})
        elif k == "compress":
            o.add(c, "", "compress", {"payload": i["payload"]}, {"compressed": e["compressed"]})
            if e.get("compressed"):
                o.add(c, "#inflate", "inflate", {"stream": e["compressed"], "size": len(unhex(i["payload"]))},
                      {"payload": i["payload"]})
        elif k == "padding":
            o.add(c, "", "pad", {"data": i["data"], "target": i["target"]}, {"padded": e["padded"]})
        elif k == "optimal_block_size":
            o.add(c, "", "block", {"size": i["size"]}, {"block": e["block"]})
        elif k == "unpad":
            o.add(c, "", "unpad", {"data": i["data"]}, {"unpadded": e["unpadded"]})
        elif k == "packet_encode":
            ops_packet_encode(o, c)
        elif k == "packet_reencode_preserves_wire":
            ops_packet_reencode(o, c, by_len)
        elif k == "packet_decode_reject":
            o.add(c, "", "packet_decode", {"bytes": i["bytes"]}, {"decodes": False})
        elif k == "packet_decode_accept":
            exp = {"decodes": True, "payload": e["payload"]}
            if "route" in e:
                exp["route"] = e["route"]
            o.add(c, "", "packet_decode", {"bytes": i["bytes"]}, exp)
        elif k == "peer_id":
            key = i.get("noise_public_key", i.get("noise_static_pubkey"))
            o.add(c, "", "peer_id", {"key": key}, {"peer_id": e["peer_id"]})
        elif k == "capabilities":
            if "raw" in i:
                o.add(c, "", "caps_encode", {"raw": big(i["raw"])}, {"encoded": e["encoded"]})
            else:
                o.add(c, "", "caps_decode", {"bytes": i["encoded"]},
                      {"raw": big(e["raw"]), "reencoded": get(e, "reencoded")})
        elif k == "announce_tlv" and "nickname" in i:
            ios = src == "ios"
            ann = {"nickname": i["nickname"],
                   "noise": i["noise_public_key"] if ios else i["noise_key"],
                   "signing": i["signing_public_key"] if ios else i["signing_key"],
                   "caps": big(i.get("capabilities")),
                   "neighbors": i.get("direct_neighbors"), "geohash": i.get("bridge_geohash")}
            o.add(c, "", "announce_encode", ann, {"encoded": e["encoded"]})
            if e.get("encoded") is not None:
                if ios and "roundtrip" in e:
                    rt = e["roundtrip"]
                    exp = {"decodes": True, "nickname": rt["nickname"], "noise": rt["noise_public_key"],
                           "signing": rt["signing_public_key"], "caps": big(rt.get("capabilities")),
                           "neighbors": rt.get("direct_neighbors"), "geohash": rt.get("bridge_geohash")}
                else:
                    exp = {"decodes": True, "nickname": e.get("decoded_nickname", ann["nickname"]),
                           "noise": ann["noise"], "signing": ann["signing"],
                           "caps": big(e.get("decoded_capabilities_raw"))}
                o.add(c, "#decode", "announce_decode", {"bytes": e["encoded"]}, exp)
        elif k in ("announce_tlv", "announce_decode"):
            b = i.get("encoded", i.get("bytes"))
            if e.get("decodes", True) is False:
                o.add(c, "", "announce_decode", {"bytes": b}, {"decodes": False})
                continue
            if src == "ios":
                exp = {"decodes": True, "nickname": get(e, "nickname"), "noise": get(e, "noise_public_key"),
                       "signing": get(e, "signing_public_key"), "caps": big(e.get("capabilities")),
                       "neighbors": e.get("direct_neighbors"), "geohash": e.get("bridge_geohash")}
            else:
                exp = {"decodes": True, "nickname": get(e, "nickname"), "noise": get(e, "noise_key"),
                       "signing": get(e, "signing_key"), "caps": big(e.get("capabilities_raw")),
                       "reencoded": get(e, "reencoded")}
            o.add(c, "", "announce_decode", {"bytes": b}, exp)
        elif k == "peer_state_tlv":
            if "bytes" in i:
                exp = {"decodes": e.get("decodes", True)}
                if exp["decodes"]:
                    exp.update(caps=big(e["capabilities"]) if "capabilities" in e else _ABSENT,
                               signing=get(e, "signing_public_key"))
                o.add(c, "", "peer_state_decode", {"bytes": i["bytes"]}, exp)
            else:
                o.add(c, "", "peer_state_encode", {"caps": big(i["capabilities"]), "signing": i["signing_public_key"]},
                      {"encoded": e["encoded"]})
        elif k == "private_message_tlv":
            if "message_id" in i:
                o.add(c, "", "pm_encode", {"message_id": i["message_id"], "content": i["content"]},
                      {"encoded": e["encoded"]})
                if e.get("encoded") is not None:
                    o.add(c, "#decode", "pm_decode", {"bytes": e["encoded"]},
                          {"decodes": True, "message_id": i["message_id"], "content": i["content"]})
            else:
                b = i.get("bytes", i.get("encoded"))
                dec = e.get("decodes", True)
                exp = {"decodes": dec}
                if dec:
                    exp["message_id"] = get(e, "message_id") if "message_id" in e else get(e, "decoded_message_id")
                    exp["content"] = get(e, "content") if "content" in e else get(e, "decoded_content")
                o.add(c, "", "pm_decode", {"bytes": b}, exp)
        elif k == "noise_payload":
            if "type" in i:
                o.add(c, "", "noise_encode", {"type": i["type"], "data": i["data"]}, {"encoded": e["encoded"]})
            else:
                b = i.get("bytes", i.get("encoded"))
                dec = e.get("decodes", True)
                exp = {"decodes": dec}
                if dec:
                    exp["type"] = get(e, "type") if "type" in e else get(e, "type_value")
                    exp["data"] = get(e, "data")
                    exp["reencoded"] = get(e, "reencoded")
                o.add(c, "", "noise_decode", {"bytes": b}, exp)
        elif k == "file_packet_tlv":
            if "content" in i:
                o.add(c, "", "file_encode", {"name": i.get("file_name"), "size": big(i.get("file_size")),
                                             "mime": i.get("mime_type"), "content": i["content"]},
                      {"encoded": e["encoded"]})
            else:
                b = i.get("bytes", i.get("encoded"))
                dec = e.get("decodes", True)
                exp = {"decodes": dec}
                if dec:
                    exp.update(name=get(e, "file_name"),
                               size=big(e["file_size"]) if "file_size" in e else _ABSENT,
                               mime=get(e, "mime_type"), content=get(e, "content"),
                               reencoded=get(e, "reencoded"))
                o.add(c, "", "file_decode", {"bytes": b}, exp)
        elif k == "fragment_payload":
            if "packet" in i:
                total = e["total_fragments"]
                for idx, f in enumerate(e["fragments"]):
                    p = f["payload"]
                    o.add(c, f"#frag{idx}", "fragment_decode", {"payload": p},
                          {"decodes": True, "fragment_id": i["fragment_id"], "index": idx, "total": total,
                           "type": i["packet"]["type"], "data": p[26:]})
            else:
                o.add(c, "", "fragment_encode", {"fragment_id": i["fragment_id"], "index": i["index"],
                                                 "total": i["total"], "type": i["original_type"], "data": i["data"]},
                      {"encoded": e["encoded"]})
                o.add(c, "#decode", "fragment_decode", {"payload": e["encoded"]},
                      {"decodes": True, "fragment_id": i["fragment_id"], "index": i["index"],
                       "total": i["total"], "type": i["original_type"], "data": i["data"]})
        else:
            raise SystemExit(f"cross.py: no neutral form for kind {k!r} (case {c['name']}); extend build_ops")
    return {"source": src, "vector_source": d.get("source"), "ops": o.ops}


# --------------------------------------------------------------------------
# compare
# --------------------------------------------------------------------------

def canon(field, v):
    if v is None:
        return None
    if isinstance(v, bool):
        return v
    if field in U64 and isinstance(v, (int, str)):
        return str(int(v) & 0xFFFF_FFFF_FFFF_FFFF)
    if isinstance(v, str):
        return expand(v).lower()
    if isinstance(v, list):
        return [canon(field, x) for x in v]
    return v


def match(ledger, hits, status, op, field):
    """First ledger entry for this status whose op, field and case regexes match."""
    for n, e in enumerate(ledger):
        if (re.fullmatch(e.get("status", "mismatch"), status) and re.fullmatch(e["op"], op["op"])
                and re.fullmatch(e["field"], field) and re.search(e["cases"], op["case"])):
            hits[n] += 1
            return e
    return None


def short(v):
    s = json.dumps(v)
    return s if len(s) <= 72 else s[:69] + "…"


def compare(args):
    ops = json.load(open(args.ops))
    res = json.load(open(args.results))
    out = {r["id"]: r for r in res["results"]}
    ledger = [] if args.source == args.target or not args.ledger else [
        e for e in json.load(open(args.ledger))["divergences"]
        if e["source"] == args.source and e["target"] == args.target]
    hits = {i: 0 for i in range(len(ledger))}
    explained, unexplained, errors, not_modeled, ok = [], [], [], [], 0
    gaps_explained = []

    def gap(op, field, why):
        # A field the target codec cannot express or does not report is data
        # it would drop: it needs a ledger entry like any byte mismatch.
        e = match(ledger, hits, "not_modeled", op, field)
        (gaps_explained if e else not_modeled).append((op["id"], field, why if not e else e["reason"]))
    for op in ops["ops"]:
        r = out.get(op["id"])
        if r is None:
            errors.append((op["id"], "observer produced no result"))
            continue
        if "error" in r:
            errors.append((op["id"], r["error"]))
            continue
        if r.get("unsupported"):
            gap(op, "*", r["unsupported"])
            continue
        got = r["out"]
        for field, want in op["exp"].items():
            if field not in got:
                gap(op, field, "target reports no such field")
                continue
            a, b = canon(field, want), canon(field, got[field])
            if a == b:
                ok += 1
                continue
            m = {"id": op["id"], "op": op["op"], "case": op["case"], "field": field,
                 "source_value": want, "target_value": got[field]}
            why = match(ledger, hits, "mismatch", op, field)
            (explained if why else unexplained).append((m, why))
    stale = [ledger[n] for n, h in hits.items() if h == 0]

    d = f"{args.source} -> {args.target}"
    print(f"== cross-replay {d}: {len(ops['ops'])} ops, {ok} fields agree")
    for m, why in explained:
        print(f"  EXPLAINED  {m['op']}/{m['field']} {m['case']}: {why['reason'][:90]}")
    for m, _ in unexplained:
        print(f"  MISMATCH   {m['op']}/{m['field']} {m['case']}\n"
              f"             {args.source}: {short(m['source_value'])}\n"
              f"             {args.target}: {short(m['target_value'])}")
    for i, f, why in gaps_explained:
        print(f"  GAP-EXPLAINED {i} {f}: {why[:80]}")
    for i, f, why in not_modeled:
        print(f"  NOT-MODELED {i} {f}: {why}")
    for i, why in errors:
        print(f"  ERROR      {i}: {why}")
    for e in stale:
        print(f"  STALE      ledger entry no longer reproduces: {e['op']}/{e['field']} /{e['cases']}/ — {e['reason'][:80]}")
    print(f"   {len(explained)} explained, {len(unexplained)} unexplained, "
          f"{len(gaps_explained)} explained gaps, {len(not_modeled)} unexplained gaps in {args.target}, "
          f"{len(errors)} errors, {len(stale)} stale ledger entries")
    if args.report:
        json.dump({"direction": d, "agree": ok,
                   "explained": [dict(m, reason=w["reason"]) for m, w in explained],
                   "unexplained": [m for m, _ in unexplained],
                   "not_modeled": [{"id": i, "field": f, "why": w} for i, f, w in not_modeled],
                   "errors": [{"id": i, "why": w} for i, w in errors], "stale": stale},
                  open(args.report, "w"), indent=1)
    return 1 if (unexplained or not_modeled or errors or stale) else 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("ops")
    a.add_argument("vectors")
    a.add_argument("out")
    b = sub.add_parser("compare")
    for f in ("--ops", "--results", "--source", "--target"):
        b.add_argument(f, required=True)
    b.add_argument("--ledger")
    b.add_argument("--report")
    args = p.parse_args()
    if args.cmd == "ops":
        res = build_ops(args.vectors)
        json.dump(res, open(args.out, "w"), indent=1)
        print(f"{args.vectors}: {len(res['ops'])} neutral ops from source={res['source']}")
        return 0
    return compare(args)


if __name__ == "__main__":
    sys.exit(main())
