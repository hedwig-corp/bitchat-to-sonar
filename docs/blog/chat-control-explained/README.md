---
title: Chat Control, explained — what Brussels just voted on, and why your private messages are the battlefield
cat: Policy
date: 2026-07-14
summary: On July 10 the European Parliament revived message scanning even though more MEPs voted against it than for it. If you've never heard of "Chat Control", start here — what it is, what just happened, and what actually protects a conversation.
author: The Sonar team
read: 8 min read
feature: true
---

# Chat Control, explained — what Brussels just voted on, and why your private messages are the battlefield

If you've never heard the words "Chat Control", here is the short version: for five years the European Union has been debating whether the services you use to talk to your friends — WhatsApp, Instagram DMs, Gmail, Signal — should scan your private messages for illegal content before or while they deliver them. Supporters call it child protection. Critics call it mass surveillance. Both are talking about the same machinery.

Last week that machinery survived a vote it technically lost. It's worth understanding how, because it says a lot about where this is going.

## What "Chat Control" actually is

The name covers two different EU laws that people constantly mix up:

- **Chat Control 1.0** — a *temporary exception* to EU privacy rules, in force since 2021. It doesn't force anyone to scan, but it makes it **legal** for platforms to voluntarily scan private messages, photos and emails for known child sexual abuse material (CSAM). This is what Google, Microsoft and Meta already do on Gmail, Instagram DMs, Xbox and similar services.
- **Chat Control 2.0** — the *permanent* Child Sexual Abuse Regulation (CSAR), still being negotiated. Earlier drafts went much further: they would have **required** scanning, including on end-to-end encrypted apps, using a technique called *client-side scanning* — software on your own phone that inspects messages **before** they are encrypted.

The distinction matters, but the direction of travel is one line: normalize scanning as legal, then argue about making it mandatory.

## What just happened

The temporary regime was about to expire. In April 2026 the Parliament rejected extending it. Then, in the week before summer recess, it came back.

First, MEPs voted 331–304 to use an **urgent procedure** — skipping the normal committee process — to force a fresh vote. The Greens' negotiator [Markéta Gregorová didn't mince words](https://euperspectives.eu/2026/07/parliament-forced-back-to-the-chat-control-question/):

> Despite my warning on the plenary floor that today's vote violates our own rules of procedure, the European Parliament decided to use an urgent procedure for Chat Control 1.0. This is unprecedented. This is no longer just about protecting privacy, it is about protecting our democracy. No means no.

Then came the vote itself, on **July 10, 2026** — the day before recess, with many seats empty. A majority of MEPs present voted **against** the extension: 314 to 276. It passed anyway. Why? Because under the second-reading rules, killing the measure required an **absolute majority of all 720 members — 361 votes** — and every absent MEP effectively counted as a yes. Opponents fell 47 votes short. [As The Record reported](https://therecord.media/chat-control-2-csam-scans-european-parliament-passage), voluntary scanning is now legal **until April 3, 2028**.

Supporters see this as basic child safety. Europol's executive director Catherine De Bolle [put it this way](https://therecord.media/chat-control-2-csam-scans-european-parliament-passage):

> Enabling online service providers to continue detecting and reporting suspected CSAM to the competent authorities is vital for the protection of children.

Civil-liberties groups see the same text very differently. Simeon de Brouwer of European Digital Rights described what the regime lets platforms do: [scan](https://therecord.media/chat-control-2-csam-scans-european-parliament-passage)

> snoop without a warrant, with little to no oversight, and with no legal basis, on millions of conversations.

And the Center for Democracy and Technology called the maneuver that revived it an ["unprecedented tactic"](https://therecord.media/chat-control-2-csam-scans-european-parliament-passage) built on "highly politicised procedural efforts."

## The encryption fight isn't over — it's next

One genuinely important line survived in the extended text: communications protected by **end-to-end encryption are excluded** from voluntary scanning. Signal, WhatsApp and other E2EE messengers are formally out of Chat Control 1.0's reach.

But the permanent regulation — Chat Control 2.0 — is still in trilogue negotiations, and that is where encryption's future gets decided. The Council [dropped mandatory client-side scanning from its position in late 2025](https://www.globalencryption.org/2026/01/gec-steering-committee-statement-on-council-of-the-eu-position-on-the-european-csa-regulation/) after years of pressure from cryptographers and civil society, but it kept "risk-mitigation obligations" broad enough that regulators could still pressure encrypted services to weaken their protocols. Negotiations continue through 2026.

Digital-rights advocate Patrick Breyer, who has fought this file for years, [summarized what the Parliament has been pushing for instead](https://euperspectives.eu/2026/07/parliament-forced-back-to-the-chat-control-question/):

> In these negotiations, the EU Parliament has been advocating for a paradigm shift in online child protection: mandatory detection orders targeting suspects instead of indiscriminate mass scanning.

That's the actual policy debate: targeted investigation of suspects versus scanning everyone. Everything else is detail.

## Why "just scan a little" doesn't work

Client-side scanning sounds surgical: only illegal content, only flagged matches. But the machinery is general-purpose. A system that can match your photos against one database can match them against any database — and what counts as reportable is a policy decision that can change after the infrastructure exists. False positives are unavoidable at the scale of billions of messages, and every false positive is a stranger reviewing a private photo. And once a device is built to report on its owner, end-to-end encryption becomes a formality: the message was read before it was sealed.

This is why cryptographers keep repeating the same uncomfortable truth: **there is no such thing as a backdoor that only lets the good guys in.**

## So what's the solution?

Two things, and they work on different timescales.

**1. Political pressure — it demonstrably works.** The Council dropping mandatory client-side scanning didn't happen out of kindness; it happened because scientists, companies and hundreds of thousands of citizens pushed back for years. The July vote passed by a procedural technicality, not by conviction — a majority of the MEPs in the room said no. Campaigns like [Fight Chat Control](https://fightchatcontrol.eu) make it easy to see where your country stands and contact your MEPs before the permanent regulation lands. The decisive window is the CSAR trilogue, expected to conclude in late 2026.

**2. Architecture that has nothing to hand over.** Laws change with every parliament. Privacy that depends on a company's promise — or a legal carve-out that survived by 47 votes — can be legislated away in an afternoon. Privacy that is a property of the **architecture** cannot. That means:

- **End-to-end encryption with forward secrecy**, so even a future key compromise can't unlock past conversations.
- **No accounts and no phone numbers**, so there is no user database to subpoena and no social graph to leak.
- **No central servers**, so there is no single company that can be ordered to insert a scanner.
- **Open source clients**, so a scanner can't be added quietly — anyone can read exactly what the app does before a message is sealed.

## This is what we're building

That architecture isn't hypothetical. It's an open protocol stack, and it already runs.

[**White Noise**](https://whitenoise.chat) is a secure messenger built on open standards — Nostr, Blossom and MLS — via the **Marmot Protocol**. In its own words, it's "a secure and private messenger that's lightning fast, scalable, and identity-free." Messages get end-to-end encryption with **forward secrecy and post-compromise security** (the same MLS cryptography standardized by the IETF), and instead of one company's servers, thousands of independent relays carry the traffic. No phone number, no email, no account — your identity is a key generated on your device.

**Sonar** is the full-featured app built on that same foundation — same Marmot encryption, same no-account identity — and takes it one step further: it works **even without the internet**. When the people you're talking to are nearby, messages hop phone-to-phone over a Bluetooth mesh; when they're far, they travel over open Nostr relays. Same conversation, same encryption, different road — the bubble color even tells you which. On top of that: group chats, voice and video calls, voice notes, stickers, media sharing, and payments that move through the chat as easily as a message. There is no server to seize, no account database to subpoena, and no closed component where a scanner could hide.

Chat Control is a reminder that privacy you have to trust someone to honor is privacy you can lose in a single afternoon of legislating — sometimes in a half-empty chamber, the day before recess. Privacy that is built into the architecture is a great deal harder to take away.

That's the kind we're building.

---

*Sonar is free and open source. [Read the docs](Sonar%20Docs.html) or [get the app](Sonar%20Landing.html).*
