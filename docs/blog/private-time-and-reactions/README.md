---
title: A reaction, and the time where you are — without telling the relays
cat: Product
date: 2026-09-28
summary: Alpha.15 adds emoji reactions and a private local time. Both travel inside the encrypted chat. Relays see ordinary ciphertext, not a public like and not your timezone.
author: The Sonar team
read: 6 min read
feature: false
---
# A reaction, and the time where you are — without telling the relays

Two small things change how a chat feels, and both of them were easy to build the wrong way.

A reaction is a tap. Local time is a glance: it is 4:10 where they are, six hours behind you. Most messengers implement both by publishing them. The like becomes a public event. The timezone lands on the profile, next to the name, where anyone who can see the profile can see it.

Sonar 1.15 does neither.

## Reactions stay inside the chat

Long-press a message and pick an emoji. A chip appears on the bubble. The other person sees the same chip. Add another, change it, remove it. Reopen the chat and it is still there.

That is the whole feature from the outside. Underneath, the reaction is a kind-7 rumor carried inside the encrypted group message, the same shape White Noise already uses, so a Marmot peer can react back without a special case. It is not a public like on a relay. Relays see the same ciphertext they see for any other message in that chat.

A reaction does not become a new row in the transcript, an unread count, or a push notification. It updates the message it belongs to. If a reaction never makes it out, it drops off the tally, and you can react again.

## Local time is opt-in, and it never leaves the chat

Settings → Privacy & safety → **Share local time** is off until you turn it on. You can also override it for one person, or one group, from their info screen.

When it is on, a direct chat header can show something like `4:10 PM · 6 hours behind`. In a group, each member's local time sits under their name, including yours. The clock moves only while the screen is open. It does not poll the network to do that.

The zone travels the same private path as a reaction: inside MLS, never on the public profile, never in a Bluetooth announce, never in a geohash channel. Relays see ordinary group ciphertext. Turning the setting off stops publishing. A wipe clears the per-chat overrides.

The phone computes the offset itself. What gets shared is the IANA zone name, checked as a zone name, not a free-form string. Contacts do not receive a raw dump of how your device is configured beyond that.

## What 1.15.1 fixed

1.15.0 shipped this, and then a bug made launch painful for some installs. An older test build had stamped the local conversation index with a schema version this release did not expect. The app opened with no index, the home list looked empty, and because the "already shared" record lived in that index, the app re-sent the local-time share into every group on every reopen. Hundreds of publishes in the first minute. Relays rate-limited the account.

1.15.1 repairs the index on open and does not fan that share out again. If 1.15.0 left you with an empty home, update. You should not need to reinstall. Kill the app, reopen it, and the chats should be there within a couple of seconds. Leave it in the foreground for a minute. It should stay quiet.

## What to try

- Long-press a message, react, and confirm the other device shows the chip after you both reopen the chat.
- Turn on **Share local time**, open a direct chat, and look at the header. Turn it off again and confirm it stops.
- If you installed 1.15.0 and the home list was empty, install 1.15.1 and reopen. The list should fill from the phone.

The other half of this release is the wallet. That is a separate post: [the wallet is now Cashu](https://sonarprivacy.xyz/blog/#cashu-wallet).
