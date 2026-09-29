---
title: The wallet is now Cashu
cat: Product
date: 2026-09-28
summary: Sonar 1.15 moves the wallet to Cashu. Balance, send, receive, in-chat pay, and your handle all live there. Breez stays only as a legacy wallet, and it is never deleted out from under you.
author: The Sonar team
read: 7 min read
feature: false
---
# The wallet is now Cashu

Sending money in Sonar was already supposed to feel like sending a message. Alpha.13 put pay next to compose, so you did not have to open a chat first. Alpha.15 changes what sits behind that button.

The wallet is now Cashu, on iOS and Android. Balance, send, receive, the lightning button in a chat, Unify, and the address on your handle all use it. Breez, the wallet previous builds created, is still there if you already had one. It is legacy. New installs do not get one.

## What you should see

Update from 1.14. Your identity, nickname, and contacts should still be there. The wallet should come up as Cashu, with a balance in sats and a fiat estimate where we have a rate.

Send a payment in a chat. The bubble moves from sending to paid. The activity list is newest first: amount, person, rail, fee, status. Before you confirm a nearby Unify send, the app shows the amount and the fee. The fee on screen is the most that send will pay. A higher one is refused and offered again, not silently taken.

Receive still announces once, as a line in the chat or a banner, not both.

If the mint is unreachable, the app retries in the background. It should not sit on a stuck "connecting" state, and it should not crash. When the mint answers, it recovers.

Paying someone who has never published an address is blocked. That is a refusal, not a crash.

## Your address should survive a reinstall

The awkward failure of a new wallet is a new address. Someone still has the old one. They pay it. Nothing arrives.

Cashu in this cut keeps one offer, and that offer can be restored. It is backed up to your account's relays. Reinstall, restore the account, and the wallet republishes the backed-up offer. It does not mint a fresh one and orphan the address your contacts already have. History comes back from your encrypted backup if you had turned **Backup chats** on. Otherwise local chats start empty. The identity and the wallet come from the key.

A send the mint never answered is not marked failed. It stays pending and is settled by a watcher. A send the mint refused is failed. A payment that first looked failed and later completes should read paid, not stay stuck on the earlier answer.

## What happens to the old wallet

Breez is not deleted because you updated. It is not deleted because the new wallet came up. A new install never creates one. If you already had funds there, they stay until you move them.

The public handle moves to the Cashu wallet only after a confirmed move. An old Breez wallet is offered for removal only after two synced passes find it empty, and that removal stops if anything arrived after the check. You can delete it yourself only once the funds are provably safe. If the old balance looks wrong after the update, that is the report we want, not something to click through.

## What else is in 1.15

This cut is not only the wallet.

- **Reactions.** Long-press a message, pick an emoji. The chip stays in the encrypted chat. It is not a public like.
- **Share local time.** Off by default. When you turn it on, contacts in that encrypted chat can see the time where you are. The zone does not go on your public profile.
- **Note to Self.** A pinned chat that never leaves the phone. No invites, no member list. Delete it and it comes back empty.
- **Share a file.** From another app, the other person gets the file, not a path. A folder is refused. The same document is not sent twice.

1.15.1 is the build to install. 1.15.0 could open with an empty home and then republish a local-time share into every group. 1.15.1 repairs that on open. Kill the app, reopen it, and the chats should paint from the phone.

Reactions and local time have their own note: [a reaction, and the time where you are](https://sonarprivacy.xyz/blog/#private-time-and-reactions).

If a payment looks wrong, or the home list stays empty after 1.15.1: **Settings → Diagnostics → Share**, and send the log.
