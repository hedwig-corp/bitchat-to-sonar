#!/usr/bin/env python3
"""Embed docs/HERMES-AGENT.md into web/src/lib/docs-content.js."""
import re
from pathlib import Path

def js_escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace("`", "\\`").replace("${", "\\${")

repo = Path("/tmp/bitchat-to-sonar")
md = (repo / "docs/HERMES-AGENT.md").read_text(encoding="utf-8")
js_path = repo / "web/src/lib/docs-content.js"
js = js_path.read_text(encoding="utf-8")

escaped = js_escape(md)
entry_body = f"""
    'HERMES-AGENT': {{
      title: 'Hermes Agent',
      status: 'integration',
      gh: 'https://github.com/hedwig-corp/bitchat-to-sonar/blob/main/docs/HERMES-AGENT.md',
      blurb: 'autonomous hermes agent over sonar dms via sonar-cli and gateway',
      md: `{escaped}`,
    }}"""

if "'HERMES-AGENT':" in js:
    js = re.sub(
        r"\n    'HERMES-AGENT': \{.*?\n    \},",
        "\n" + entry_body + ",",
        js,
        count=1,
        flags=re.DOTALL,
    )
    print("Refreshed HERMES-AGENT entry")
else:
    js = js.replace(
        "    { name: 'Content', items: ['SONAR-STICKERS'] },\n  ],",
        "    { name: 'Content', items: ['SONAR-STICKERS'] },\n    { name: 'Integrations', items: ['HERMES-AGENT'] },\n  ],",
    )
    old = "- **[Stickers](SONAR-STICKERS.md)** — the open sticker-pack directory published on Nostr."
    new = old + "\n- **[Hermes Agent](HERMES-AGENT.md)** — autonomous AI over Sonar DMs via sonar-cli and the Hermes gateway."
    if old in js:
        js = js.replace(old, new)
    js = js.replace(
        "    },\n  },\n};\n",
        f"    }},{entry_body},\n  }},\n}};\n",
        1,
    )
    print("Inserted HERMES-AGENT entry")

js_path.write_text(js, encoding="utf-8")
print("Updated", js_path, "size", len(js))