// Sonar blog — original posts. Body is markdown (rendered by the same parser as Docs).
window.SONAR_BLOG = {
  posts: [
    {
      id: 'chat-control-back-door',
      title: 'Chat Control passed. Here\u2019s why Sonar was built for exactly this moment.',
      cat: 'Policy',
      date: 'July 12, 2026',
      read: '6 min read',
      author: 'The Sonar team',
      feature: true,
      excerpt: 'The EU Parliament advanced client-side scanning through a procedural side door. Mandated scanning breaks the one promise a private messenger makes \u2014 so we designed Sonar to have nothing to hand over.',
      md: `# Chat Control passed. Here\u2019s why Sonar was built for exactly this moment.

This week the European Parliament advanced a version of the long-contested "Chat Control" regulation \u2014 not through a clean public vote on the merits, but folded into a broader procedural package where the scanning mandate drew far less scrutiny than it deserved.

The mechanism at the heart of it is **client-side scanning**: software on your own phone inspects your messages *before* they are encrypted and sent, comparing them against a database and reporting matches. Proponents call it a targeted safety measure. Cryptographers, civil-liberties groups, and a long line of security researchers call it what it is \u2014 a mandated backdoor on every private conversation.

> Once a device is built to scan and report on its owner, encryption is no longer a promise. It is a formality that ends the moment the message leaves your keyboard.

## Why "just scan the bad stuff" doesn\u2019t hold

The pitch is always narrow: scan for one specific category of illegal content. But the machinery is general-purpose. A system that can match your messages against *one* list can match them against *any* list. The database is opaque, the matching runs on your hardware, and the list of what counts as reportable is a policy decision \u2014 one that can change without you ever knowing.

Three problems compound:

1. **Scope creep is structural, not hypothetical.** The same code that scans for one thing is one config change away from scanning for another.
2. **False positives are unavoidable.** Perceptual matching flags innocent images, and a flag can mean a human reviewer \u2014 or law enforcement \u2014 sees your private photos.
3. **It breaks the threat model for everyone.** Journalists, abuse survivors, doctors, dissidents, and ordinary people all lose the same guarantee at once.

## What actually protects a conversation

End-to-end encryption only means something if **no one but the participants can read the message \u2014 including the platform, and including the device before it sends.** The moment scanning is inserted anywhere in that path, the guarantee is gone regardless of what the marketing says.

That leads to a simple design principle: the safest data is the data that never exists in a place anyone can compel.

## How Sonar is built for this

Sonar was not designed as a reaction to this vote \u2014 but it was designed around the assumption that platforms get pressured and infrastructure gets seized. Every architectural choice reduces what there is to hand over:

- **No accounts, no phone numbers, no servers.** There is no user database to subpoena because there is no user database. Your identity is a key generated on your device and never uploaded.
- **A Bluetooth mesh that works with no internet at all.** When you\u2019re near the people you\u2019re talking to, messages hop phone-to-phone. No relay, no ISP, nothing in the middle to tap.
- **Open Nostr relays for everything else.** When you\u2019re out of range, messages travel over relays nobody owns \u2014 and any relay can be swapped for another. There is no single provider to serve an order to.
- **Client-side scanning is architecturally impossible to bolt on quietly** because the client is open source. Anyone can read exactly what the app does before your message is sealed. There is no closed component where a scanner could hide.

## This is why open and decentralized matters now

Centralized messengers are a single point of pressure. One legal order, one jurisdiction, one infrastructure provider \u2014 and the guarantee bends for everyone at once. A decentralized, offline-capable, account-free network has no such lever. There is no company to compel, no server to raid, and no central place where your messages sit waiting to be scanned.

Chat Control is a reminder that privacy you have to *trust a company to honor* is privacy you can lose in a single afternoon of legislating. Privacy that is a property of the **architecture** is a great deal harder to take away.

That\u2019s the kind we\u2019re building.

*Sonar is free and open source. [Read the protocol docs](Sonar%20Docs.html) or [try the app](Sonar%20Prototype.html).*`,
    },
    {
      id: 'why-no-accounts',
      title: 'Why Sonar has no accounts \u2014 and why that\u2019s the point',
      cat: 'Design',
      date: 'June 30, 2026',
      read: '4 min read',
      author: 'The Sonar team',
      excerpt: 'Most messengers start by asking for your phone number. Sonar never does. Here\u2019s what that changes about who can see your social graph \u2014 and who can\u2019t.',
      md: `# Why Sonar has no accounts \u2014 and why that\u2019s the point

Almost every messenger begins the same way: enter your phone number, wait for a code, upload your contacts. It feels normal. It is also the single biggest privacy leak most people never think about.

## Your phone number is an identifier for everything

A phone number ties your messaging to your real-world identity, your carrier, your billing address, and \u2014 through contact upload \u2014 a map of everyone you know. That social graph is often more revealing than the messages themselves. Who you talk to, when, and how often tells a story even when the content is encrypted.

## Sonar\u2019s identity is a key, not a number

When you first open Sonar, it generates a keypair on your device. That key *is* your identity. There is no signup, no verification code, no server that records "this number joined." You can hand someone your public key in person by letting them scan a QR code \u2014 and nothing about that exchange touches a central directory.

- Nothing links your identity to your phone number or SIM.
- There is no contact upload, so your social graph never leaves your device.
- Losing your phone doesn\u2019t "lock you out of an account" \u2014 there is no account, only a key you can back up yourself.

## The tradeoff, honestly

No accounts means no "forgot password" and no company-side recovery. If you lose your key and your backup, that identity is gone. We think that\u2019s the right tradeoff for a tool whose entire purpose is that no one else holds your keys \u2014 and we designed key export and restore so backing up is a deliberate, understandable step.

*More on identity in the [discovery docs](Sonar%20Docs.html).*`,
    },
    {
      id: 'mesh-when-internet-goes-down',
      title: 'What happens to your messages when the internet goes down',
      cat: 'Engineering',
      date: 'June 16, 2026',
      read: '5 min read',
      author: 'The Sonar team',
      excerpt: 'Protests, disasters, festivals, dead zones \u2014 the moments you most need to reach people are often the moments the network fails. Sonar\u2019s mesh is built for them.',
      md: `# What happens to your messages when the internet goes down

Cellular networks fail in predictable ways: during protests they get throttled or shut off, during disasters they get overwhelmed, at festivals and in remote areas they simply aren\u2019t there. These are exactly the moments when reaching the people around you matters most.

## Phone-to-phone, no infrastructure required

Sonar carries a **Bluetooth mesh**. When the people you\u2019re messaging are physically nearby, their phones relay messages directly to each other \u2014 hopping across intermediate devices to extend range \u2014 with no cell tower, no Wi-Fi, and no server involved.

\`\`\`text
you  ->  nearby phone  ->  nearby phone  ->  recipient
   (each hop is a direct encrypted Bluetooth link)
\`\`\`

The network is the people in the room. Add more people and the mesh gets *stronger*, not weaker.

## Encrypted the whole way

Mesh delivery doesn\u2019t mean relaxed security. Direct messages stay end-to-end encrypted across every hop \u2014 an intermediate phone that relays your message can\u2019t read it. It only sees ciphertext passing through.

## And when someone\u2019s far away

The moment a recipient isn\u2019t in Bluetooth range, Sonar seamlessly routes over open Nostr relays instead. You don\u2019t choose a mode; the app picks the path and shows you which one it used \u2014 nearby over Bluetooth, or over the internet. Same conversation, same encryption, different road.

*The bubble color even tells you how each message traveled. [See it in the app](Sonar%20Prototype.html).*`,
    },
  ],
};
