#!/usr/bin/env python3
"""Embed docs/HERMES-AGENT.md into web/src/lib/docs-content.js."""
from pathlib import Path

def js_escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace("`", "\\`").replace("${", "\\${")

repo = Path("/tmp/bitchat-to-sonar")
md = (repo / "docs/HERMES-AGENT.md").read_text(encoding="utf-8")
js_path = repo / "web/src/lib/docs-content.js"
js = js_path.read_text(encoding="utf-8")

if "'HERMES-AGENT':" in js:
    print("HERMES-AGENT already present")
    raise SystemExit(0)

escaped = js_escape(md)
entry = f"""
    'HERMES-AGENT': {{
      title: 'Hermes Agent',
      status: 'integration',
      gh: 'https://github.com/hedwig-corp/bitchat-to-sonar/blob/main/docs/HERMES-AGENT.md',
      blurb: 'autonomous hermes agent over sonar dms via sonar-cli and gateway',
      md: `{escaped}`,
    }},"""

js = js.replace(
    "    { name: 'Content', items: ['SONAR-STICKERS'] },\n  ],",
    "    { name: 'Content', items: ['SONAR-STICKERS'] },\n    { name: 'Integrations', items: ['HERMES-AGENT'] },\n  ],",
)

old = "- **[Stickers](SONAR-STICKERS.md)** — the open sticker-pack directory published on Nostr."
new = old + "\n- **[Hermes Agent](HERMES-AGENT.md)** — autonomous AI over Sonar DMs via `sonar-cli` and the Hermes gateway."
if old in js and "HERMES-AGENT" not in js.split("index:")[1][:2500]:
    js = js.replace(old, new)

js = js.replace(
    "    },\n  },\n};\n",
    f"    }},{entry}\n  }},\n}};\n",
    1,
)

js_path.write_text(js, encoding="utf-8")
print("Updated", js_path, "size", len(js))