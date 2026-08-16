// Sonar AI — sample data: models, MCP connectors, skills, chats, scripted runs
window.AI_DATA = {
  models: [
    { id: 'pocket', name: 'Sonar Pocket', sub: '3B · runs on this iPhone', where: 'device', desc: 'Nothing leaves the device. Fast, good for everyday questions.' },
    { id: 'nimbus', name: 'Nimbus 70B', sub: 'Your node · encrypted over Nostr', where: 'node', desc: 'Runs on your own hardware. Prompts are sealed to your node key.' },
    { id: 'atlas', name: 'Atlas 120B', sub: 'Paid · Nostr DVM marketplace', where: 'dvm', price: 21, desc: 'Frontier-class. Anonymous pay-per-request over Lightning — no account.' },
    { id: 'scout', name: 'Scout 8B Fast', sub: 'Paid · Nostr DVM marketplace', where: 'dvm', price: 3, desc: 'Cheap and quick for bulk work.' },
  ],
  connectors: [
    { id: 'calendar', name: 'Calendar', icon: 'clock', scope: 'device', desc: 'Events and reminders on this iPhone', tools: ['list_events', 'create_event'] },
    { id: 'files', name: 'Notes & Files', icon: 'doc', scope: 'device', desc: 'Search and read your local notes', tools: ['search', 'read_file'] },
    { id: 'wallet', name: 'Lightning Wallet', icon: 'bolt', scope: 'device', sensitive: true, desc: 'Balance, invoices and payments', tools: ['get_balance', 'pay_invoice'] },
    { id: 'nostr', name: 'Nostr Social', icon: 'globe', scope: 'web', desc: 'Read your feed, post notes', tools: ['read_feed', 'publish_note'] },
    { id: 'web', name: 'Web Search', icon: 'search', scope: 'web', desc: 'Queries leave the device (through a relay)', tools: ['search', 'fetch_page'] },
    { id: 'home', name: 'Home Node', icon: 'drive', scope: 'node', desc: 'Sensors and automations on your node', tools: ['read_sensors', 'run_automation'] },
  ],
  skills: [
    { id: 'recap', name: 'Meeting recap', icon: 'list', src: 'installed', desc: 'Turns raw notes into decisions + action items', uses: ['files'] },
    { id: 'translate', name: 'Live translator', icon: 'globe', src: 'installed', desc: 'Translate in the tone you actually speak', uses: [] },
    { id: 'satbrief', name: 'Sats market brief', icon: 'coin', src: 'installed', desc: 'Morning Bitcoin brief from your own sources', uses: ['web'] },
    { id: 'packing', name: 'Trip packing list', icon: 'pin', src: 'mine', desc: 'Your packing checklist prompt, weather-aware', uses: ['web', 'calendar'] },
    { id: 'nodewatch', name: 'Node watchdog', icon: 'drive', src: 'nostr', author: 'nettle', zaps: 412, desc: 'Checks channels, disk and backups on your node', uses: ['home'] },
    { id: 'inboxzero', name: 'Nostr inbox zero', icon: 'inbox', src: 'nostr', author: 'Maya', zaps: 268, desc: 'Triage mentions and DMs into 3 piles', uses: ['nostr'] },
  ],
  chats: [
    { id: 'c-day', title: 'Plan my Thursday', model: 'pocket', time: '18:12', preview: 'Done — I moved the deep-work block to 9:00.' },
    { id: 'c-node', title: 'Node disk warning', model: 'nimbus', time: '16:40', preview: 'The channel backup is fine; disk is at 82%.' },
    { id: 'c-brief', title: 'Sats market brief', model: 'atlas', time: 'Mon', preview: 'Short version: fees low, funding neutral.' },
  ],
  msgs: {
    'c-day': [
      { role: 'user', text: 'what does my Thursday look like?', via: 'device', time: '18:10' },
      { tool: true, server: 'calendar', name: 'list_events', args: '{ "range": "thursday" }', result: '3 events · 09:30 standup, 12:30 lunch w/ Maya, 15:00 dentist', time: '18:10' },
      { role: 'ai', model: 'pocket', time: '18:11', text: 'Three things: standup at 9:30, lunch with Maya at 12:30, dentist at 15:00. Your morning is otherwise clear — good slot for deep work before standup.' },
      { role: 'user', text: 'move my deep-work block there', via: 'device', time: '18:12' },
      { tool: true, server: 'calendar', name: 'create_event', args: '{ "title": "Deep work", "at": "thu 09:00" }', result: 'created · thu 09:00–09:30', time: '18:12' },
      { role: 'ai', model: 'pocket', time: '18:12', text: 'Done — I moved the deep-work block to 9:00.' },
    ],
    'c-node': [
      { role: 'user', text: 'my node sent a disk alert, how bad is it?', via: 'node', time: '16:38' },
      { tool: true, server: 'home', name: 'read_sensors', args: '{ "host": "basement-node" }', result: 'disk 82% · cpu 12% · channels 9/9 up · last backup 04:00', time: '16:39' },
      { role: 'ai', model: 'nimbus', time: '16:40', text: 'Not urgent. The channel backup is fine; disk is at 82%. Old Bitcoin Core logs are the bulk of it — pruning them frees about 40 GB. Want me to run the cleanup automation?' },
    ],
    'c-brief': [
      { role: 'user', text: 'run my morning sats brief', via: 'dvm', time: 'Mon' },
      { tool: true, server: 'web', name: 'search', args: '{ "q": "bitcoin fees funding rates" }', result: '6 sources · mempool.space, 2 exchanges, 3 feeds', time: 'Mon' },
      { role: 'ai', model: 'atlas', time: 'Mon', text: 'Short version: fees low (2 sat/vB floor), funding neutral, no unusual on-chain flows. A good morning to rebalance channels cheaply.' },
      { receipt: true, sats: 21, time: 'Mon' },
    ],
  },
  scenarios: {
    day: { chip: 'What\u2019s my day look like?', steps: [
      { t: 'think', ms: 900 },
      { t: 'tool', server: 'calendar', name: 'list_events', args: '{ "range": "today" }', result: '2 events · 12:30 lunch w/ Maya, 18:30 lake with the crew', ms: 1300 },
      { t: 'say', text: 'Light day: lunch with Maya at 12:30 and the lake at 18:30. Nothing in the morning — want me to protect it as focus time?' },
    ] },
    notes: { chip: 'Summarize my meeting notes', steps: [
      { t: 'think', ms: 800 },
      { t: 'tool', server: 'files', name: 'search', args: '{ "q": "meeting", "recent": true }', result: '1 match · "co-op sync 12 Aug.md" (1.4 KB)', ms: 1200 },
      { t: 'tool', server: 'files', name: 'read_file', args: '{ "path": "co-op sync 12 Aug.md" }', result: 'read 1.4 KB', ms: 900 },
      { t: 'say', text: 'Three decisions from the co-op sync: the market stall moves to Saturdays, Luca owns the flyer, and the budget vote is deferred to next week. One action item is yours — send the vendor list to Sofia by Friday.' },
    ] },
    pay: { chip: 'Pay the router invoice', steps: [
      { t: 'think', ms: 700 },
      { t: 'tool', server: 'wallet', name: 'get_balance', args: '{}', result: '182 400 sats spendable', ms: 900 },
      { t: 'tool', server: 'wallet', name: 'pay_invoice', args: '{ "to": "isp@bolt12.org", "amount": "12 000 sats" }', result: 'settled · preimage 9f2c\u2026e81a', ms: 1900, amount: '12 000 sats (\u20ac9.60)' },
      { t: 'say', text: 'Paid — 12 000 sats to isp@bolt12.org, settled in 1.9 s. I filed the receipt under Utilities.' },
    ] },
    web: { chip: 'Anything new in the Marmot spec?', steps: [
      { t: 'think', ms: 700 },
      { t: 'tool', server: 'web', name: 'search', args: '{ "q": "marmot protocol spec changelog" }', result: '4 results · spec repo, 2 blog posts, 1 nostr thread', ms: 1600 },
      { t: 'say', text: 'One real change: last week the spec merged key-package rotation on a 30-day schedule. Practical effect — group invites expire faster, so stale invite links die on their own. The rest is editorial.' },
    ] },
  },
  memory: [
    { id: 'm1', text: 'Prefers answers in English; notes are in Italian', time: 'Jul 2' },
    { id: 'm2', text: 'Runs a basement node called "basement-node" (LND + Core)', time: 'Jul 9' },
    { id: 'm3', text: 'Deep-work block is sacred: weekday mornings', time: 'Jul 18' },
    { id: 'm4', text: 'Budget answers in sats first, EUR in parentheses', time: 'Aug 1' },
  ],
  npub: 'npub1w4j8mc7q0e2v9zk5xr3thl6f8s2a7d4ynq9c3uxe650pgh8vrtsq4k9dj',
  generic: [
    'On it. Give me one more detail and I\u2019ll make it concrete \u2014 otherwise here\u2019s my best read: keep it simple, do the smallest version first, and let me automate the boring half.',
    'Good question. Short answer: yes, and it stays on this phone \u2014 I didn\u2019t need any tools for that one.',
  ],
};

function aiNow() {
  const d = new Date();
  return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
}
window.aiNow = aiNow;
