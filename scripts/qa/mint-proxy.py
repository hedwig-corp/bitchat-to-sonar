#!/usr/bin/env python3
"""mint-proxy.py — a fault-injecting HTTP proxy in front of a local QA mint.

Point the app at the proxy instead of the mint (iOS DEBUG:
`-sonar.debug.cashuMintURL http://127.0.0.1:<listen>`), then arm one fault at
a time through the control port. It exists to reproduce what a real network
does to a wallet: a melt whose answer never comes back, a melt request that
reaches the mint late, a mint that answers after the wallet gave up. Test
sats only: use it with a `cdk-mintd` fakewallet mint, never a real one.

    scripts/qa/mint-proxy.py --listen 8095 --upstream 8085 --control 8099 &
    scripts/qa/mint-proxy.py arm lose-melt-answer      # forward, apply, drop the answer
    scripts/qa/mint-proxy.py arm drop-melt             # close the connection; keep the request
    scripts/qa/mint-proxy.py deliver                   # ...and deliver it to the mint now
    scripts/qa/mint-proxy.py discard                   # ...or forget it: it never arrives
    scripts/qa/mint-proxy.py arm delay-melt 12         # forward after 12 s (the app waits)
    scripts/qa/mint-proxy.py arm delay-mint-answer 20  # mint issues at once, answer after 20 s
    scripts/qa/mint-proxy.py status | disarm

Each fault fires once, on the next matching request, then the proxy is back
to passing traffic through. `status` prints the log of what fired.

Requests go upstream one per connection (`Connection: close`) and the
client's connection is closed after each answer, which every HTTP client
handles; nothing else about the traffic is changed.
"""
import argparse
import asyncio
import json
import sys
import time
import urllib.request

MELT = ("/v1/melt/bolt11", "/v1/melt/bolt12")
MINT = ("/v1/mint/bolt11", "/v1/mint/bolt12")

state = {"fault": None, "arg": None, "held": None, "log": []}


def log(event: str) -> None:
    line = f"{time.strftime('%H:%M:%S')} {event}"
    state["log"].append(line)
    print(line, flush=True)


async def read_request(reader):
    head = await reader.readuntil(b"\r\n\r\n")
    lines = head.decode("latin-1").split("\r\n")
    method, path, _ = lines[0].split(" ", 2)
    length = 0
    for line in lines[1:]:
        if line.lower().startswith("content-length:"):
            length = int(line.split(":", 1)[1].strip())
    body = await reader.readexactly(length) if length else b""
    return method, path, head, body


def rewrite_close(head: bytes) -> bytes:
    """The same request head with `Connection: close` (one request per connection)."""
    lines = [l for l in head.decode("latin-1").split("\r\n") if l and not l.lower().startswith("connection:")]
    return ("\r\n".join(lines) + "\r\nConnection: close\r\n\r\n").encode("latin-1")


async def upstream_roundtrip(port: int, head: bytes, body: bytes) -> bytes:
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    writer.write(rewrite_close(head) + body)
    await writer.drain()
    answer = await reader.read()  # until EOF: Connection: close
    writer.close()
    return answer


def close_answer(answer: bytes) -> bytes:
    """Mark the answer `Connection: close`, since we close after it."""
    sep = answer.find(b"\r\n\r\n")
    if sep < 0:
        return answer
    head = [l for l in answer[:sep].decode("latin-1").split("\r\n") if not l.lower().startswith("connection:")]
    return ("\r\n".join(head) + "\r\nConnection: close\r\n\r\n").encode("latin-1") + answer[sep + 4:]


def take(fault: str):
    if state["fault"] != fault:
        return None
    arg = state["arg"]
    state["fault"], state["arg"] = None, None
    return arg if arg is not None else True


async def handle(reader, writer, upstream: int):
    try:
        method, path, head, body = await read_request(reader)
    except (asyncio.IncompleteReadError, ValueError, ConnectionError):
        writer.close()
        return
    is_melt = method == "POST" and path.startswith(MELT)
    is_mint = method == "POST" and path.startswith(MINT) and "/quote/" not in path
    try:
        if is_melt and take("drop-melt"):
            state["held"] = (head, body)
            log(f"drop-melt: {path} held, connection closed without an answer")
            writer.close()
            return
        if is_melt and (delay := take("delay-melt")):
            log(f"delay-melt: holding {path} for {delay} s before the mint sees it")
            await asyncio.sleep(float(delay))
        answer = await upstream_roundtrip(upstream, head, body)
        if is_melt and take("lose-melt-answer"):
            log(f"lose-melt-answer: {path} applied by the mint, answer dropped")
            writer.close()
            return
        if is_mint and (delay := take("delay-mint-answer")):
            log(f"delay-mint-answer: {path} issued by the mint, answer held {delay} s")
            await asyncio.sleep(float(delay))
        writer.write(close_answer(answer))
        await writer.drain()
    except (ConnectionError, OSError) as e:
        log(f"{method} {path}: {e}")
    finally:
        writer.close()


async def control(reader, writer, upstream: int):
    try:
        _, path, _, body = await read_request(reader)
        cmd = json.loads(body or b"{}")
        op = cmd.get("op")
        if op == "arm":
            state["fault"], state["arg"] = cmd["fault"], cmd.get("arg")
            log(f"armed {state['fault']} {state['arg'] or ''}".rstrip())
        elif op == "disarm":
            state["fault"], state["arg"] = None, None
            log("disarmed")
        elif op == "discard":
            had = state["held"] is not None
            state["held"] = None
            log("discard: held melt forgotten" if had else "discard: nothing held")
        elif op == "deliver":
            if state["held"] is None:
                raise ValueError("no melt request is held")
            head, body = state["held"]
            state["held"] = None
            answer = await upstream_roundtrip(upstream, head, body)
            status = answer.split(b"\r\n", 1)[0].decode("latin-1")
            log(f"deliver: held melt reached the mint late ({status})")
        out = json.dumps({"fault": state["fault"], "arg": state["arg"],
                          "held": state["held"] is not None, "log": state["log"][-20:]})
        code = "200 OK"
    except Exception as e:  # noqa: BLE001 — report any control error to the caller
        out, code = json.dumps({"error": str(e)}), "400 Bad Request"
    data = out.encode()
    writer.write(f"HTTP/1.1 {code}\r\nContent-Type: application/json\r\nContent-Length: {len(data)}\r\n"
                 f"Connection: close\r\n\r\n".encode() + data)
    await writer.drain()
    writer.close()


async def serve(args):
    proxy = await asyncio.start_server(lambda r, w: handle(r, w, args.upstream), "127.0.0.1", args.listen)
    ctl = await asyncio.start_server(lambda r, w: control(r, w, args.upstream), "127.0.0.1", args.control)
    log(f"proxy 127.0.0.1:{args.listen} -> 127.0.0.1:{args.upstream}; control on {args.control}")
    async with proxy, ctl:
        await asyncio.gather(proxy.serve_forever(), ctl.serve_forever())


def send_control(port: int, payload: dict) -> int:
    req = urllib.request.Request(f"http://127.0.0.1:{port}/", data=json.dumps(payload).encode(), method="POST")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            print(r.read().decode())
            return 0
    except urllib.error.HTTPError as e:
        print(e.read().decode(), file=sys.stderr)
        return 1


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("arm", "disarm", "deliver", "discard", "status"):
        port = 8099
        rest = sys.argv[2:]
        if "--control" in rest:
            i = rest.index("--control")
            port = int(rest[i + 1])
            rest = rest[:i] + rest[i + 2:]
        op = sys.argv[1]
        payload = {"op": op}
        if op == "arm":
            payload["fault"] = rest[0]
            payload["arg"] = rest[1] if len(rest) > 1 else None
        sys.exit(send_control(port, payload))
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--listen", type=int, default=8095)
    p.add_argument("--upstream", type=int, default=8085)
    p.add_argument("--control", type=int, default=8099)
    asyncio.run(serve(p.parse_args()))


if __name__ == "__main__":
    main()
