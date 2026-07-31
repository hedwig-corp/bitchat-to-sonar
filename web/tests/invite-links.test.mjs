import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  inviteTokenFromHash,
  openInSonarHref,
} from "../static/join/open-in-sonar.js";

const token = "sinvite1aabbcc";

test("extracts an invite token from the private URL fragment", () => {
  assert.equal(inviteTokenFromHash(`#${token}`), token);
  assert.equal(inviteTokenFromHash("#not-an-invite"), null);
});

test("uses the Sonar custom scheme on Apple platforms", () => {
  assert.equal(
    openInSonarHref(
      token,
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X)",
    ),
    `sonar://invite/${token}`,
  );
});

test("targets the installed Sonar package from Android browsers", () => {
  const href = openInSonarHref(
    token,
    "Mozilla/5.0 (Linux; Android 16; Pixel 10)",
  );
  assert.match(href, new RegExp(`^intent://invite/${token}#Intent;`));
  assert.match(href, /scheme=sonar;/);
  assert.match(href, /package=chat\.bitchat\.sonar;/);
  assert.match(
    href,
    /S\.browser_fallback_url=https%3A%2F%2Fgithub\.com%2Fhedwig-corp%2Fbitchat-to-sonar%2Freleases%2Flatest;/,
  );
});

test("Digital Asset Links authorizes the published Android release certificate", async () => {
  const raw = await readFile(
    new URL("../static/.well-known/assetlinks.json", import.meta.url),
    "utf8",
  );
  const assetLinks = JSON.parse(raw);
  // Assert the whole statement, not just the fingerprint: an emptied relation
  // or namespace breaks App Links verification while leaving the fingerprint
  // sitting right there, which a fingerprint-only check reads as healthy.
  const sonarTargets = assetLinks.filter(
    (entry) =>
      entry.target?.namespace === "android_app" &&
      entry.target?.package_name === "chat.bitchat.sonar" &&
      (entry.relation ?? []).includes(
        "delegate_permission/common.handle_all_urls",
      ),
  );
  assert.ok(sonarTargets.length > 0, "no delegating statement for Sonar");

  const fingerprints = sonarTargets.flatMap(
    (entry) => entry.target.sha256_cert_fingerprints ?? [],
  );
  assert.ok(
    fingerprints.includes(
      "84:A7:FA:65:6D:E5:82:77:20:F6:A4:A2:48:93:93:C8:24:C6:73:15:B9:DE:FE:A3:41:19:C6:EE:4C:93:13:D6",
    ),
    "sideload release certificate is not authorized",
  );
});
