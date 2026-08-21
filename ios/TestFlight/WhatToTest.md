# TestFlight — What to Test

Build: **Sonar 1.14 (44)** · release tag **v0.1-alpha.14**

Headline: **reply to any message** (#587) and **@mentions in groups** (#561, #601).
Reliability pass on chat-open crashes (#597, #599), duplicate push banners (#590),
and the backup data-plan fix (#567). Mesh hardening: verified public packets (#505),
reassembly expiry (#494), welcome auto-accept gating (#498).

## 1. Reply to a message (headline)

Swipe/long-press a bubble → Reply → send. The quoted parent must render on both
ends and survive app restarts, on iOS and Android, in DMs and groups.

- Reply over **internet (Marmot)**: quote renders on the peer's device.
- Reply over **Bluetooth/mesh**: same. On the sending device, verify the reply row
  carries the quoted parent, not just a bare message.
- **Known gap (α.15 target, #594):** if you arm a reply against a mesh-delivered
  row and the Bluetooth link drops before you hit send, the message goes out as
  ordinary Marmot text **without the quote**. Known — don't file new reports;
  do note how often you hit it in the wild.
- Reply rows in a transcript with many replies: no duplicated/mis-nested quotes
  after fast scrolling (crash fix territory from #597/#599).

## 2. @mention people in groups

In a group, type `@` → member picker appears; pick a member (or keep typing to
filter). The mention renders as a chip matching the design (#601); the picked
member should be notifiable by name.

- Chips must render on the **other side** too, not just for the author.
- A mention of a member who then leaves the group must not crash the transcript.

## 3. Backup stops eating the data plan (#567)

With Backup on, background upload traffic must be bounded — no more
multi-GB uploads on metered connections (66 GB in one billing period was the
report). Leave Backup on over cellular for a day and watch the app's data usage.

## 4. Chat-open reliability

- Open chats rapidly, including conversations with call rows and reply rows —
  no crash (#597), no crash on rows with empty inline metadata (#599).
- iOS: opening a chat paints from local history instantly, never a blank
  transcript while waiting for sync (#507); cold start must not stall behind
  identity publishes (#508).
- One notification per event: no duplicate inline banners after a timed-out
  notify job (#590).

## 5. Mesh hardening spot-checks

- Public mesh messages/files from a **pinned peer** must still be signature-verified (#505).
- Leave an idle BLE session half-open; new sessions after the idle window must
  reassemble fine instead of the pool being permanently wedged (#494).
- An unsolicited 2-member "welcome" from an unknown sender must not auto-accept
  or grow local storage (#498).

## 6. Smaller

- Onboarding screens scroll when content overflows (#591).
- Short iOS transcripts stay visible when the keyboard opens (#595); Signal-style
  transcript scroll and Home invalidation perf (#598).
- Desktop: no more offer of calls it cannot make or take (#589); Linux voice
  notes actually play (#568).
- Mesh photos arrive at full intended quality, not crushed to 448px (#593).
- Profile fields set by other Nostr clients survive Sonar's kind-0 republish (#584).
