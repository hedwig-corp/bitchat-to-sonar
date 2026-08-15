---
title: v0.1-alpha.13 — the release that stopped getting killed
cat: Engineering
date: 2026-08-01
summary: You can now pay someone without opening a chat first. Plus six rounds chasing a single iOS crash signature, Lightning that arrives while the app is dead, a pile of transcript bugs that all looked like "my message disappeared", and a full walkthrough of how encrypted account backup works — down to what deliberately is not in the archive.
author: The Sonar team
read: 11 min read
feature: false
---
# v0.1-alpha.13 — the release that stopped getting killed

Alpha.12 was about identity: [one handle to chat and to get paid](https://sonarprivacy.xyz/blog/#release-alpha-12). Alpha.13 is about the far less glamorous question that follows it — *does the thing actually stay running?*

Forty-two pull requests landed between alpha.12 and now, and the honest summary is that most of them are bug fixes. Several are fixes to bugs we had already "fixed" once. That is the story worth telling, so this post leads with it.

## Six rounds of `0xdead10cc`

`0xdead10cc` is an iOS termination signature with a very specific meaning: your app held a file lock on something in shared storage while the system suspended it. iOS does not negotiate. It kills you.

Sonar's Marmot chat database is SQLCipher in an App Group container, which is exactly the kind of file iOS means. When the app went to the background, the store had to be closed. We shipped that fix in [#446](https://github.com/hedwig-corp/bitchat-to-sonar/pull/446). Then we shipped it again. And again.

- **Round 2 ([#448](https://github.com/hedwig-corp/bitchat-to-sonar/pull/448))** — the close was queued behind a background prefetch on the same serial queue. It was scheduled, then starved.
- **Round 3 ([#449](https://github.com/hedwig-corp/bitchat-to-sonar/pull/449))** — a relay sync already parked inside blocking Rust could not be preempted at all, so we had to make it abortable rather than merely await it.
- **Round 5 ([#538](https://github.com/hedwig-corp/bitchat-to-sonar/pull/538))** — the close was armed off the drain completing. When the drain never completed, the close was never *reached*.
- **Round 6 ([#544](https://github.com/hedwig-corp/bitchat-to-sonar/pull/544), [#545](https://github.com/hedwig-corp/bitchat-to-sonar/pull/545))** — a background auto-backup reopened the store it had just closed, and a connect still in flight at suspension held it open before any node existed to close.

Each round asked a genuinely different question. What *blocks* the close? What *reopens* the store? Why was the close never *reached*? Was there even a node yet? A fix that answers one of those does nothing for the others, which is precisely why it took six.

The lesson we wrote down: an un-aborted blocking call parked in Rust is proof the close never ran, and a lease in the log is proof the store was open. Those two tells now short-circuit the diagnosis from days to minutes. Round 6 was diagnosed in about thirty seconds from logs pulled read-only off the reporting device.

## How account backup actually works

[#368](https://github.com/hedwig-corp/bitchat-to-sonar/pull/368) shipped encrypted account backup end to end. Since it is the feature most likely to matter on the worst day you have with this app — the day you lose the phone — it is worth explaining properly rather than just announcing.

*If you just want to know what it does for you and what to do about it, [start here instead](https://sonarprivacy.xyz/blog/#backup-explained) — this section is the engineering detail underneath it.*

The design constraint is stated in one line at the top of the module: **Blossom sees ciphertext only.** Everything else follows from that.

### One secret, two layers

Sonar's chat database is SQLCipher, encrypted at rest with a `db_key` that is random and host-owned. That key is deliberately *not* your `nsec` — the local database should not be readable by anyone who learns your account key from somewhere else.

But a backup you cannot open on a fresh phone is not a backup. So the sealed archive carries both the database *and* its key, and the whole bundle is wrapped with a key derived from your account secret:

```
wrapping_key = HKDF-SHA256(
    ikm  = nsec (32 bytes),
    salt = "sonar-backup",
    info = "sonar-account-backup-v1",
)
```

That wrapping key encrypts the bundle with **ChaCha20-Poly1305** under a fresh random 12-byte nonce, prepended to the ciphertext. The plaintext inside is three things: the `db_key`, the Marmot database bytes, and the conversation index. Nothing else.

So the chain is: your `nsec` unwraps the `db_key`, and the `db_key` unlocks the database. One secret you already have, two layers, and no server anywhere in the trust path. The archive is domain-separated by that HKDF `info` string, so the same account secret used for a different purpose cannot produce a key that opens it.

Before sealing, the database's write-ahead log is TRUNCATE-checkpointed into the main file. A SQLCipher file whose WAL is still sitting beside it is not self-contained, and an archive that restores to a half-written database is worse than no archive.

### Where it goes, and how it is found again

The sealed blob is uploaded to Blossom with its own MIME type, `application/vnd.sonar.account-backup-v1`. That is not cosmetic: restore has to pick *the backup* out of a listing that also contains your media, and a distinct content type is how it does that.

Backups live on Hedwig's own Blossom server. There is one wrinkle worth knowing: media and backups are found differently. A media attachment carries an absolute URL inside the message, so it can always be fetched from wherever it was originally put. **A backup has no stored URL** — restore finds it by *listing* a host and taking the newest blob. That means moving the default host would orphan every backup already sitting on the old one, so the previous host is kept as a read-only fallback that restore tries after the current default comes up empty.

### When it runs

Backup policy is owned by the core, in a small sidecar file next to the database. Hosts do not decide when to back up; they ask whether it is due and execute if so.

- A **dirty** flag is set whenever local transcript or index state changes.
- Dirty triggers an opportunistic backup after a **30-minute debounce**, so a busy conversation produces one upload, not forty.
- Even a completely quiet account gets a **daily** archive, so a reinstall never restores something ancient.
- The debounce applies after *failures* too. A server that is down must not turn into a retry loop.

It is worth saying where that first bullet comes from, because it is not really a scheduling trick. Sonar can back up in response to your own local state because the archive is a self-contained sealed blob addressed by your account key — the client owns the whole loop, start to finish. WhatsApp's backups land in iCloud or Google Drive, so the cadence is a bucket you pick in a settings screen, the archive sits in a platform account tied to your phone number, and the key to open it is either in a vendor-run vault or on a piece of paper you hopefully still have. Nothing stops them from noticing when a chat changed. What they cannot do is put the result somewhere that is addressed by you and readable by no one else, because the archive was never theirs to address.

The subtle part is the dirty flag's lifecycle. Clearing it on a successful upload is the obvious implementation and it is wrong: messages that arrive *while the archive is being sealed and uploaded* are not in that archive, and clearing the flag would drop them from the next one too. So the policy carries a monotonic `dirty_seq` counter. An attempt snapshots it; success clears dirty **only** if no newer mark arrived in the meantime. Otherwise the account stays dirty and backs up again.

[#533](https://github.com/hedwig-corp/bitchat-to-sonar/pull/533) fixed a related bug in the same machinery: the 12-hour floor was re-arming itself out of existence, so an account could go far longer than intended without an archive. [#540](https://github.com/hedwig-corp/bitchat-to-sonar/pull/540) carried a restored backup's stats into the live policy, so the Settings strip describes the archive you actually have rather than showing a blank.

### Assuming the server is hostile

A restore downloads and unwraps a file chosen by whatever a server hands back. That server is not part of the trust model, and [#496](https://github.com/hedwig-corp/bitchat-to-sonar/pull/496) hardened both halves of the transfer accordingly.

**Byte caps bound memory.** A downloaded archive is refused past 200 MiB. The listing that precedes it is capped separately at 4 MiB — it is descriptors only, one small JSON object per blob, so even a pathological account fits far under that, while a server streaming gigabytes of JSON fails fast. The blob download had a cap before this change; the listing did not, and it was buffered whole.

**Deadlines bound time.** No size cap catches a server that accepts your connection and then simply never replies — that is not a large transfer, it is a hang. Each transfer gets a fixed 60-second allowance plus what its payload would take on a deliberately pessimistic link, capped at twenty minutes.

That second one matters more than it sounds, and specifically on iOS. The app closes the Marmot node *before* sealing, and only clears its in-flight fence when the upload returns. A request that hangs forever leaves you with no chat and no relay for the rest of the session — and latches the fence so every later backup attempt is skipped too. A backup feature that can silently disable both messaging and itself is a worse failure than a backup that errors.

### Restoring

Paste your `nsec` into a fresh install. Sonar lists the backup host, takes the newest sealed blob, unwraps it with the key derived from that secret, and writes the database and index back into place. Identity and wallet come back from the key itself; chat history comes back from the archive.

If the secret is wrong or the file is damaged, the AEAD tag fails and you get one honest error — *wrong nsec or corrupt* — rather than a partially-restored database. There is no degraded path, on purpose.

The account key remains the account. The backup is a convenience layered on top of it, never a replacement for it — which is also why the restore screen will not let a failed unwrap quietly replace a working account.

### What is not in it

Two limits worth stating plainly.

**Messages that travelled over Bluetooth are not in the archive.** Sonar stores mesh history separately from the Marmot database, and the backup snapshots the database. If you and a contact talk mostly in person over the mesh and only occasionally over the internet, a restore brings back the internet half of that conversation and not the Bluetooth half. We are [tracking that gap](https://github.com/hedwig-corp/bitchat-to-sonar/issues/552); it is a real hole, not a design decision, and the fix is to give mesh messages the same storage the internet ones already have.

**A backup is only as durable as your key.** Nothing in this system can recover an account whose `nsec` is gone. That is the trade for a server that never holds anything but ciphertext, and it is the right trade — but it means the one thing genuinely worth writing down is still the key.

## Paying someone — and getting paid while your app is dead

### You can now just pay someone

Until this release, sending money meant opening a chat with the person first. [#491](https://github.com/hedwig-corp/bitchat-to-sonar/pull/491) adds a standalone flow: **Start a chat → Send a payment**, then pick a contact, paste an address or a BOLT12 offer, or scan a QR code. It landed on all four surfaces — Android, desktop, iOS, macOS — in one change.

*There is a [plain-language walkthrough of the payment flow](https://sonarprivacy.xyz/blog/#paying-people) if you would rather see it from the outside; what follows is what had to be fixed underneath.*

![The Start a chat sheet, with Send a payment listed alongside People nearby, Find by username, and New group](https://sonarprivacy.xyz/blog/alpha13-start-a-chat.png)

*Paying someone is now a peer of starting a conversation, not something buried inside one.*

![The Send payment screen: a search field accepting a name, username, domain or Bolt12 offer, a Scan a QR code row, and a People you can pay list](https://sonarprivacy.xyz/blog/alpha13-send-payment.png)

*One field takes a contact, a Lightning address, or a BOLT12 offer. Only people who publish a payment address are listed — payments settle straight to their wallet, with no claim step.*

Getting there meant fixing two payment types that could not actually be paid. **BOLT11 invoices failed outright**, because Breez takes the amount from the invoice itself while Sonar was also passing its own — found in a device log line reading `AmountMissing: "Expected invoice with an amount"`. And a **BIP-21 unified URI** like `bitcoin:bc1q…?lno=lno1…` was treated as a plain on-chain address, so the BOLT12 offer sitting in `lno=` was quietly ignored and the whole URI handed to the wallet.

Worse than either: when a payment failed, you frequently saw nothing at all. The outcome was being written to a screen that had already been popped off the stack. Result toasts are now hosted once at the app root, so an outcome cannot be delivered to a view that no longer exists. Relatedly, [#442](https://github.com/hedwig-corp/bitchat-to-sonar/pull/442) stopped the bitcoin payment option vanishing from chats where it belonged.

[#493](https://github.com/hedwig-corp/bitchat-to-sonar/pull/493) then went after the word *sending*. Resolving an address, finding a route, an HTLC in flight, and a settled proof were all hiding behind it — which is precisely the moment you want to know where your money is. Every state now answers three questions: what is happening, where is my money, and what do I do next. "Failed", on its own, is never an answer to the second one.

And **Max** ([#506](https://github.com/hedwig-corp/bitchat-to-sonar/pull/506)) stopped proposing your entire balance. Lightning fees are charged on top of what the receiver gets, so "all of it" was never a payable amount — it failed locally with a raw SDK string *after* you had already committed. Max now offers your balance minus a small reserve (0.5%, clamped between 10 and 1000 sats), and still answers instantly, because a tap must never wait on the network to tell you a number.

### Receiving while the app is dead

The hardest payment case is not a slow network. It is a recipient whose app is not running.

[#295](https://github.com/hedwig-corp/bitchat-to-sonar/pull/295) closed the Android half: a BOLT12 `invoice_request` push now gets answered even when the app has been killed, so an offline peer can still be paid. The wake chain had been fine for months — the payload was arriving in about forty milliseconds and then being dropped on the floor, unanswered, because nothing on the receive side knew how to reply to it.

## "My message disappeared"

A cluster of bugs shared one user-facing symptom and had almost nothing in common underneath.

- [#522](https://github.com/hedwig-corp/bitchat-to-sonar/pull/522) / [#523](https://github.com/hedwig-corp/bitchat-to-sonar/pull/523) — a vanishing *Sending* bubble on both platforms, same symptom, two unrelated causes: an iOS transcript apply that skipped the frame carrying the new row, and an Android echo retired before its canonical row was in the window.
- [#539](https://github.com/hedwig-corp/bitchat-to-sonar/pull/539) — desktop **Return** sent the draft the view graph remembered instead of the one the field was holding, so the last characters you typed were dropped.
- [#541](https://github.com/hedwig-corp/bitchat-to-sonar/pull/541) — internet replies that only the chat list could see. The row was ahead of the transcript because incoming internet DMs are stored under a key the transcript's resolver never produced.
- [#507](https://github.com/hedwig-corp/bitchat-to-sonar/pull/507) / [#441](https://github.com/hedwig-corp/bitchat-to-sonar/pull/441) — chats that opened blank, or landed mid-history with the unread divider drifting.
- [#543](https://github.com/hedwig-corp/bitchat-to-sonar/pull/543) — short transcripts now bottom-align and re-pin when the viewport shrinks, instead of leaving a blank band above the keyboard.

Every one of these is the same underlying hazard: Sonar renders one conversation, but a person can reach you over Bluetooth *or* over the internet, and the two legs are stored differently. Code that quietly assumes one shape breaks the other. We keep a [written ledger of these](https://github.com/hedwig-corp/bitchat-to-sonar/blob/main/docs/REGRESSIONS.md) precisely because several have now returned more than once.

## Security and identity

[#462](https://github.com/hedwig-corp/bitchat-to-sonar/pull/462) binds a Noise session to the identity its handshake actually authenticated, closing the gap where a session could be reused under a claimed-but-unproven peer identity. [#472](https://github.com/hedwig-corp/bitchat-to-sonar/pull/472) keeps one stable KeyPackage slot per install rather than minting a fresh one every launch. [#528](https://github.com/hedwig-corp/bitchat-to-sonar/pull/528) patched two remote-DoS advisories in our Nostr dependency.

The one worth calling out plainly is [#447](https://github.com/hedwig-corp/bitchat-to-sonar/pull/447). Sharing a link into Sonar from Safari, with no recipient chosen, fell through to a **public mesh broadcast** — a link you meant for one person went to everyone in Bluetooth range. Both platforms now route every share through a recipient picker. If you shared anything into Sonar before this release, that is the bug you may have hit.

## Discovery, desktop, and the build itself

[#444](https://github.com/hedwig-corp/bitchat-to-sonar/pull/444) stopped iOS nearby peers flapping in and out of discovery — the peer-retention window was shorter than the announce cadence, so contacts blinked out between announcements. [#461](https://github.com/hedwig-corp/bitchat-to-sonar/pull/461) stopped an alarming relay-connect banner from covering a chat that was working fine. [#445](https://github.com/hedwig-corp/bitchat-to-sonar/pull/445) fixed the desktop BLE bridge build on Linux and corrected the platform matrix. [#379](https://github.com/hedwig-corp/bitchat-to-sonar/pull/379) routed Android's system Back through app navigation.

And [#518](https://github.com/hedwig-corp/bitchat-to-sonar/pull/518) finally builds the iOS app in CI. For most of this project's life a Swift compile error could only be caught on someone's laptop. That gap is closed. The iOS *test* gap is not — those still do not run in CI, and we would rather say so than imply a green check means more than it does.

## What to look at

If you are testing this build, the [What to Test notes](https://github.com/hedwig-corp/bitchat-to-sonar/blob/main/ios/TestFlight/WhatToTest.md) list the specific paths. The two we most want reports on:

1. **Lock your phone mid-chat for a minute, then come back.** That is the `0xdead10cc` path. Six rounds in, we want to know if there is a seventh.
2. **Restore from `nsec` on a fresh install.** Identity, wallet balance, and — if you had Backup chats on — your history.

If something goes wrong, **Settings → Diagnostics → Share** exports a log. Export it right away; it is far more useful than a description written an hour later.

Known gaps this release does not close: some newer payment and onboarding strings are English-only and fall back rather than translate, in-app QR camera scanning is still limited (paste and share links work), and Breez wallet crashes come back unsymbolicated because the vendor SDK ships no debug symbols.

Nothing here is a headline feature. That was the point.
