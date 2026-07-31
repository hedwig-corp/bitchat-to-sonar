---
title: What happens to your chats if you lose your phone
cat: Engineering
date: 2026-08-01
summary: Sonar can now keep an encrypted backup of your conversations that only you can open — no cloud account, no company holding a spare key. Here is what it saves, what it deliberately does not, and the one thing you should do before you need it.
author: The Sonar team
read: 6 min read
feature: false
---
# What happens to your chats if you lose your phone

Phones get lost. They get stolen, dropped in water, or simply die on a Tuesday for no reason. It is worth knowing, before that happens, exactly what you would get back.

For most messaging apps the honest answer is: *it depends on a cloud account you may not think about very often.* Your chats are copied to iCloud or Google Drive, tied to an account with your real name and phone number on it, and whether anyone else can read that copy depends on settings you probably set once and forgot.

Sonar works differently, and this release is where the difference becomes something you can actually use.

## The idea in one sentence

Sonar can keep an encrypted copy of your conversations, and **the only thing that can open that copy is the key that already is your account**.

No password to invent. No recovery email. No support team who can let you back in — and, by the same token, no support team who can be persuaded, subpoenaed, or breached into letting someone else in.

## What your account actually is

If you have used Sonar for more than a few minutes you have an account key. It is a long string that starts with `nsec`, and it is not like a password — it *is* the account. Your identity, your name, your wallet, and your conversations all descend from it.

This matters for backup because it means there is nothing extra to set up. You already hold the only credential that will ever be needed. The backup is just an encrypted parcel that your existing key can unlock, sitting somewhere it can be fetched from later.

The storage server holds the parcel. It cannot open it. It does not know your name, your phone number, or who you talk to — from where it sits, your backup is an unreadable blob and nothing else.

## What comes back

Paste your key into a fresh install and you get:

- **Your identity** — same account, same name, same handle. To everyone you talk to, you are the same person you were.
- **Your wallet** — the balance is derived from the key itself, so it returns whether or not you ever turned backup on.
- **Your conversations** — if backup was on, your message history comes back with them.

That third one is what is new. The first two have always worked, because they follow from the key. History needed somewhere to be stored, and now it has one.

## What does not come back

Two things, and we would rather you hear them from us than discover them on the worst day.

**Messages sent over Bluetooth are not in the backup.** Sonar can talk two ways: over the internet, and directly phone-to-phone over Bluetooth when the other person is nearby. Those two kinds of message are stored in different places inside the app, and the backup currently only captures the internet one. If you and a friend talk mostly in person, sitting in the same room, a restore will bring back the conversations you had while apart and not the ones you had face to face. This is a gap we are fixing, not a decision we made on purpose — it is [tracked publicly](https://github.com/hedwig-corp/bitchat-to-sonar/issues/552) like everything else.

**Nothing can recover an account whose key is gone.** This is the real trade. A company that can restore your account for you is a company that can be compelled to hand it to someone else, or breached by someone who takes it. We chose the other side of that trade deliberately. It means the safety of your account rests with you, and it means one small piece of homework.

## The one thing to do today

Save your account key somewhere you will still have it if your phone is not in your hand.

A password manager is ideal. Written on paper in a drawer is genuinely fine. What matters is that it is not *only* on the device you might lose, because a key that exists in exactly one place is one accident away from being gone.

That is the whole homework. Everything else — the backups, the restore, the encryption — happens without you thinking about it.

## When it runs

You do not have to remember to back up.

Sonar notices when your conversations have changed and quietly makes a fresh backup a little while later — waiting a bit on purpose, so an active afternoon of chatting produces one backup rather than dozens. If nothing much is happening, it still refreshes about once a day, so a restore never hands you something ancient.

You can see the state of it, and turn it off, in **Settings → Data & storage**. There is also a dry run there if you would like to confirm it works before you need it to, which we would gently encourage — a backup you have never tested is a hope, not a plan.

## Restoring

On a fresh install, choose **Restore account with private key** and paste your key.

Sonar finds your most recent backup, opens it with the key, and puts your conversations back. If the key is wrong, or the file was damaged in transit, you get a single clear error and your device is left exactly as it was — there is no half-restored state where some things came back and you cannot tell which.

## Why we built it this way

It would have been easier to put your chats in iCloud and Google Drive and let the platforms deal with it. Most apps do, and it works.

But it quietly moves the answer to "who can read my messages" from *only the people in the conversation* to *the people in the conversation, plus whoever has access to that cloud account*. For an app whose entire point is that conversations stay between the people having them, that is not a small compromise. It is the compromise.

So the backup is sealed before it leaves your phone, with a key nobody else has, and stored somewhere that never learns who you are.

---

*If you want the engineering detail — how the key is derived, what the archive actually contains, how the schedule decides when to run, and what happens when the storage server misbehaves — it is written up in the [v0.1-alpha.13 release notes](https://sonarprivacy.xyz/blog/#release-alpha-13).*
