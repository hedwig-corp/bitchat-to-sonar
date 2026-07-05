#!/usr/bin/env python3
"""Post `goose review` findings to a GitHub PR.

Reads newline-delimited JSON produced by `goose review` (one JSON object per
finding, or a single `[]` line when clean) and posts to the PR:

  clean (explicit marker)    -> approve (short message)
  no parseable output        -> neutral comment (never auto-approve on silence)
  findings, no high/critical -> inline comments + summary comment (COMMENT)
  any high/critical          -> inline comments + REQUEST_CHANGES

Findings whose line range falls outside the PR diff, or that span a gap between
diff hunks, are folded into the summary so the GitHub API never returns 422 for
an out-of-range or non-contiguous line.

Usage: post_kimi_review.py <pr_number> <head_sha> <ndjson_path> [review_exit_code]

Requires the `gh` CLI on PATH and env: GH_TOKEN (or GITHUB_TOKEN),
GITHUB_REPOSITORY (owner/repo, set automatically on GitHub Actions).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from collections import defaultdict

SEVERITY_RANK = {"low": 1, "medium": 2, "high": 3, "critical": 4}


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def parse_findings(ndjson_path):
    """Return (findings, saw_clean_marker). saw_clean is True only when goose
    emitted an explicit `[]` (clean) marker — never inferred from silence."""
    findings = []
    saw_clean = False
    try:
        with open(ndjson_path, "r", encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if not line:
                    continue
                if line == "[]":
                    saw_clean = True
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue  # skip any non-JSON chatter from the agent
                if isinstance(obj, list):
                    if not obj:
                        saw_clean = True
                    continue
                if isinstance(obj, dict) and "severity" in obj:
                    findings.append(obj)
    except FileNotFoundError:
        pass
    return findings, saw_clean


def fetch_diff_lines(pr_number):
    """{path: set(valid new-file line numbers)} parsed from `gh pr diff`."""
    valid = defaultdict(set)
    res = run(["gh", "pr", "diff", str(pr_number)])
    if res.returncode != 0:
        return valid
    current_path = None
    new_line = 0
    in_hunk = False
    for raw in res.stdout.splitlines():
        if raw.startswith("diff --git "):
            current_path = None          # reset at each file boundary
            in_hunk = False
        elif not in_hunk and raw.startswith("+++ b/"):
            current_path = raw[6:]       # repo-relative path
        elif not in_hunk and raw.startswith("+++ /dev/null"):
            current_path = None          # pure deletion: no new-side lines
        elif raw.startswith("@@"):
            try:
                # handles "@@ -a,b +c,d @@" and "@@ -a +c @@" (count omitted)
                plus = raw.split("+", 1)[1]
                new_line = int(plus.split(",")[0].split()[0])
                in_hunk = True
            except (IndexError, ValueError):
                in_hunk = False
        elif in_hunk and current_path is not None and raw:
            tag = raw[0]
            if tag in (" ", "+"):
                valid[current_path].add(new_line)
                new_line += 1
            # "-" and "\" markers do not advance the new-file line counter
    return valid


def post_inline(pr_number, head_sha, repo, path, line_start, line_end, body):
    """POST one line comment via `gh api --input`. Returns True on success."""
    payload = {
        "body": body,
        "path": path,
        "line": line_end,
        "commit_id": head_sha,
        "side": "RIGHT",
    }
    if line_end != line_start:
        payload["start_line"] = line_start
        payload["start_side"] = "RIGHT"
    tmp = None
    try:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as tf:
            json.dump(payload, tf)
            tmp = tf.name
        res = run([
            "gh", "api", "--method", "POST",
            f"repos/{repo}/pulls/{pr_number}/comments",
            "--input", tmp,
        ])
        return res.returncode == 0
    finally:
        if tmp and os.path.exists(tmp):
            os.unlink(tmp)


def post_text(args, body):
    """Run a `gh` subcommand that reads its --body-file from stdin.

    Returns the gh exit code (0 = success) and warns on stderr if it failed,
    so CI logs surface a review that never landed.
    """
    r = subprocess.run(["gh", *args, "--body-file", "-"], input=body, text=True)
    if r.returncode != 0:
        print(f"warning: `gh {' '.join(args)}` failed (exit {r.returncode})",
              file=sys.stderr)
    return r.returncode


def main():
    if len(sys.argv) < 4:
        print("usage: post_kimi_review.py <pr_number> <head_sha> <ndjson> [exit_code]",
              file=sys.stderr)
        return 2
    pr_number = sys.argv[1]
    head_sha = sys.argv[2]
    ndjson_path = sys.argv[3]
    try:
        exit_code = int(sys.argv[4])
    except (IndexError, ValueError):
        exit_code = 0
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    if not repo:
        print("GITHUB_REPOSITORY not set", file=sys.stderr)
        return 2

    # Catastrophic review failure -> report it as a comment and stop.
    if exit_code != 0:
        tail = ""
        try:
            with open(ndjson_path, "r", encoding="utf-8") as fh:
                tail = "".join(fh.readlines()[-30:])
        except OSError:
            pass
        body = (
            "## Kimi review did not complete\n\n"
            "`goose review` exited non-zero. See the workflow logs for details.\n\n"
            "<details><summary>Last lines of output</summary>\n\n```\n"
            f"{tail}\n```\n</details>"
        )
        post_text(["pr", "comment", str(pr_number)], body)
        return 0

    findings, saw_clean = parse_findings(ndjson_path)

    # No findings: approve only on an explicit clean marker. If the review
    # produced no parseable output at all, do NOT silently approve.
    if not findings:
        if saw_clean:
            post_text(["pr", "review", str(pr_number), "--approve"],
                      "Kimi review: no findings on this diff. LGTM.")
            print("approved (clean marker, no findings)")
        else:
            post_text(["pr", "comment", str(pr_number)],
                      "Kimi review produced no parseable findings. "
                      "Review the diff manually before merging.")
            print("no findings and no clean marker (did not auto-approve)")
        return 0

    valid_lines = fetch_diff_lines(pr_number)

    posted, folded = [], []
    for fnd in findings:
        path = fnd.get("path", "")
        ls = int(fnd.get("line_start") or fnd.get("line") or 0)
        le = int(fnd.get("line_end") or ls or 0)
        if le < ls:
            ls, le = le, ls
        sev = str(fnd.get("severity") or "medium").lower()
        summary = (fnd.get("summary") or "(no summary)").strip()
        check = fnd.get("check") or "main"
        body = f"**[{sev.upper()}] {check}**\n\n{summary}"

        lines = valid_lines.get(path)
        if not lines or ls <= 0:
            folded.append((sev, path, ls, le, summary, check))
            continue
        candidates = [n for n in range(ls, le + 1) if n in lines]
        if not candidates:
            folded.append((sev, path, ls, le, summary, check))
            continue
        # Clamp to the first contiguous run so start_line..line never spans a
        # gap between hunks (GitHub 422s a comment whose interior is not in diff)
        run_lines = [candidates[0]]
        for n in candidates[1:]:
            if n == run_lines[-1] + 1:
                run_lines.append(n)
            else:
                break
        s, e = run_lines[0], run_lines[-1]
        ok = post_inline(pr_number, head_sha, repo, path, s, e, body)
        (posted if ok else folded).append((sev, path, s, e, summary, check))

    all_findings = posted + folded
    max_sev = max((SEVERITY_RANK.get(f[0], 2) for f in all_findings), default=1)
    verdict = "REQUEST_CHANGES" if max_sev >= SEVERITY_RANK["high"] else "COMMENT"

    by_sev = defaultdict(int)
    for sev, *_ in all_findings:
        by_sev[sev] += 1
    sev_line = ", ".join(
        f"{k}={v}" for k, v in
        sorted(by_sev.items(), key=lambda kv: -SEVERITY_RANK.get(kv[0], 2))
    )

    out = [
        "## Kimi code review", "",
        f"- Verdict: **{verdict}**",
        f"- Findings: {len(findings)} "
        f"({len(posted)} inline, {len(folded)} folded into this summary)",
    ]
    if sev_line:
        out += ["- Severity: " + sev_line]
    out += [""]

    if folded:
        out += [
            "<details><summary>Findings not attached to a diff line</summary>", "",
        ]
        for sev, path, ls, le, summary, check in folded:
            loc = f"{path}:{ls}" + (f"-{le}" if le and le != ls else "")
            out.append(f"- **[{sev.upper()}]** `{loc}` ({check}) — {summary}")
        out += ["", "</details>", ""]

    summary_md = "\n".join(out)
    if verdict == "REQUEST_CHANGES":
        post_text(["pr", "review", str(pr_number), "--request-changes"], summary_md)
    else:
        post_text(["pr", "comment", str(pr_number)], summary_md)
    print(f"posted {len(posted)} inline; verdict={verdict}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
