---
title: Sending money should feel like sending a message
cat: Engineering
date: 2026-08-01
summary: Sonar can now pay someone without opening a chat first — pick a contact, paste an address, or scan a code. No invoice to request, no claim step for them, and it works even when their phone is asleep in a pocket.
author: The Sonar team
read: 6 min read
feature: false
---
# Sending money should feel like sending a message

Think about what it currently takes to give a friend twenty euros.

You open a banking app. You find them, or type an IBAN, or discover you are on different payment apps entirely. Maybe you ask them to send you a request first. Somewhere in there you copy a long string from one app and paste it into another, and hope you got all of it.

Now think about what it takes to send them a message. You tap their name. You type. Done.

There is no good reason those should be different activities, and this release is Sonar's attempt to stop treating them as if they were.

## Paying is now a starting point, not a sub-menu

Tap the compose button — the same one you use to start a conversation — and paying someone is right there next to it.

![The Start a chat sheet, with Send a payment listed alongside People nearby, Find by username, and New group](https://sonarprivacy.xyz/blog/alpha13-start-a-chat.png)

*Before this release, sending money meant opening a chat with the person first. Now it is its own front door.*

That reordering is the whole point. Paying someone is not a thing you do *inside a conversation*; it is a thing you do *with a person*. Sometimes you have been chatting with them for months. Sometimes you just met them and want to settle a bill.

## One field, several kinds of destination

![The Send payment screen: a search field accepting a name, username, domain or Bolt12 offer, a Scan a QR code row, and a People you can pay list](https://sonarprivacy.xyz/blog/alpha13-send-payment.png)

There is one box, and it is deliberately forgiving about what you put in it:

- **A contact** — start typing a name and pick them from the list.
- **A username or address** — the `name@domain` style address that Lightning wallets use.
- **A reusable payment code** — the long string starting `lno1`, which is a modern Lightning format that can be reused instead of being good for exactly one payment.
- **A QR code** — point the camera at whatever is on the screen or the printed receipt in front of you.

You should not have to know which of those you are holding. Paste it and Sonar works it out.

## No claim step

This is the part people find surprising, so it is worth being explicit.

When you pay someone in Sonar, the money goes to their wallet. That is the end of the process. They do not receive a link. They do not have to tap **Accept**, or open the app, or create an account somewhere to collect it.

The list of people you can pay reflects this: it shows contacts who have published a payment address, because those are the people whose wallets can simply be paid. If someone is not in that list, they have not set that up yet.

## Their phone can be asleep

Here is the case that actually matters in real life: you want to pay someone, and their phone is in a pocket, screen off, app closed.

Older versions could not always handle this — the payment would sit there until the other person happened to open Sonar. In this release, a phone that is asleep, or has had the app fully closed, can still be woken to receive the money and go back to sleep. Your friend finds out they were paid when they next look at their phone, which is exactly how it should have worked all along.

This took a long time to get right on Android in particular, and the details are grim in an interesting way. They are in the release notes if you want them.

## About "Max"

A small thing that we got wrong and then fixed, because it is the kind of thing that erodes trust.

Tapping **Max** used to offer your entire balance. That sounds correct and is not, because sending money over Lightning costs a small fee *on top of* the amount your friend receives. So "all of it" was never actually sendable, and you would find out only after committing — with an unhelpful error.

Max now offers your balance minus a small amount held back for the fee. You will see a number very slightly below your total. That is not the app losing your money; it is the app leaving room for the payment to succeed.

## When something goes wrong, you can see where your money is

Payments are the one place in an app where "something went wrong" is not an acceptable message. There is a real difference between *we could not find a route*, *the payment is in flight*, and *the payment failed and your money never left* — and lumping all of them under a spinner labelled "sending" is how people end up anxiously refreshing a screen.

Every stage now tells you three things: what is happening, where your money is, and what to do next. If you close the app mid-payment, you can pick the status back up rather than being left guessing.

## What you need before any of this works

Two things.

**A wallet with something in it.** Sonar has a Lightning wallet built in. It is yours, tied to your account key — the same key that everything else in Sonar descends from. If you ever restore your account on a new phone, the balance comes back with it.

**A payment address, if you want to be paid.** Publishing one is what puts you in other people's "people you can pay" list. You can claim a readable handle so people can pay `you@sonarprivacy.xyz` from any Lightning wallet, not only from Sonar — we wrote about how handles work in [an earlier post](https://sonarprivacy.xyz/blog/#nicknames-and-group-links).

## Where this is going

Messages and money have been separate categories of app for a long time, largely for historical reasons rather than good ones. When both are just things you send to a person you already have a private channel with, keeping them apart starts to look like an accident.

There is more to do. In-app QR scanning is still limited in places, and the payment address someone publishes is not yet as discoverable as we want. But the shape is now right: you pick a person, you say an amount, and it arrives.

---

*The engineering side of this release — the payment formats that were quietly unpayable until now, how a sleeping phone gets woken to receive, and the fee reserve maths behind Max — is in the [v0.1-alpha.13 release notes](https://sonarprivacy.xyz/blog/#release-alpha-13).*
