// Sonar status — service + relay definitions and synthetic history.
// Relay latency is measured live via WebSocket; history/incidents are seeded.

window.SONAR_STATUS = {
  // Everything the app exposes, grouped like status.claude.com service rows
  services: [
    { id: 'dm', name: 'Encrypted DMs (Marmot)', desc: 'End-to-end encrypted direct messages', uptime: 99.95 },
    { id: 'groups', name: 'Group chats (White Noise)', desc: 'MLS-over-Nostr encrypted groups', uptime: 99.91 },
    { id: 'media', name: 'Media messages', desc: 'Image, video &amp; file delivery', uptime: 99.9 },
    { id: 'voice', name: 'Voice messages', desc: 'Push-to-talk voice notes', uptime: 99.93 },
    { id: 'calls', name: 'Voice &amp; video calls', desc: 'Iroh transport, Marmot signaling', uptime: 99.72, state: 'degraded' },
    { id: 'payments', name: 'Payments (Bolt12)', desc: 'Direct Lightning wallet payments', uptime: 99.94 },
    { id: 'push', name: 'Push notifications', desc: 'Encrypted push envelopes', uptime: 99.88 },
    { id: 'stickers', name: 'Stickers directory', desc: 'Nostr sticker-pack index', uptime: 100 },
  ],
  // Public Nostr relays Sonar talks to. Pinged live over WebSocket.
  relays: [
    { url: 'wss://relay.damus.io', region: 'Global · CDN' },
    { url: 'wss://nos.lol', region: 'EU · Germany' },
    { url: 'wss://relay.primal.net', region: 'US · East' },
    { url: 'wss://relay.snort.social', region: 'EU · UK' },
    { url: 'wss://nostr.wine', region: 'US · Central' },
    { url: 'wss://relay.nostr.band', region: 'Global · Anycast' },
  ],
  incidents: [
    {
      date: 'Jul 9, 2026', title: 'Elevated call setup latency', level: 'degraded',
      updates: [
        { t: '14:02 UTC', s: 'Resolved', b: 'Iroh relay capacity restored. Call setup times back to normal.' },
        { t: '13:20 UTC', s: 'Monitoring', b: 'Added relay capacity in US-East; setup times improving.' },
        { t: '12:41 UTC', s: 'Investigating', b: 'Some voice/video calls are slow to connect. Messaging is unaffected.' },
      ],
    },
    {
      date: 'Jun 28, 2026', title: 'Push notification delays (Android)', level: 'degraded',
      updates: [
        { t: '09:15 UTC', s: 'Resolved', b: 'FCM delivery normalized after upstream provider recovery.' },
        { t: '07:50 UTC', s: 'Identified', b: 'Upstream push provider degradation. Foreground/nearby delivery unaffected.' },
      ],
    },
    {
      date: 'Jun 14, 2026', title: 'Scheduled relay maintenance', level: 'maintenance',
      updates: [
        { t: '03:00 UTC', s: 'Completed', b: 'Relay pool upgraded with no user-visible downtime.' },
      ],
    },
  ],
};
