// Sonar prototype — sample data
window.BC_DATA = {
  // Explicitly joined/saved channels only — NOT every place you pass through
  channels: [
    { id: 'centro', name: 'Lugano · Centro', sub: 'Public · 12 here now', preview: 'Maya: in. I\u2019ll bring the speaker', time: '17:51', unread: 3, count: 12 },
    { id: 'city', name: 'Milano · Navigli', sub: 'Public · joined Apr 3', preview: 'Saved — quiet right now', time: '', unread: 0, count: 30 },
  ],
  // The single place you're standing in, at every precision level (narrow → wide).
  // The UI collapses this whole ladder into ONE row with a precision scale.
  here: [
    { id: 'h-bld', tier: 'building', short: 'Building', name: 'Via Nassa 5', sub: 'Public · building', count: 0 },
    { id: 'h-blk', tier: 'block', short: 'Block', name: 'Quartiere Maghetti', sub: 'Public · block', count: 2 },
    { id: 'h-hood', tier: 'neighborhood', short: 'Area', name: 'Lugano · Centro', sub: 'Public · neighborhood', count: 12 },
    { id: 'h-city', tier: 'city', short: 'City', name: 'Lugano', sub: 'Public · city', count: 48 },
    { id: 'h-prov', tier: 'province', short: 'Province', name: 'Ticino', sub: 'Public · province', count: 130 },
    { id: 'h-reg', tier: 'region', short: 'Region', name: 'Svizzera italiana', sub: 'Public · region', count: 410 },
  ],
  // inRange = reachable over Bluetooth right now; angle/r place them on the radar
  peers: [
    { id: 'maya', name: 'Maya', inRange: true, bars: 3, hint: 'Right here', detail: 'Strong signal · a few meters away', angle: 210, r: 66,
      npub: 'npub1m4yaq7r0e2v9zk5xr3thl6f8s2a7d4ynq9c3uxe650pgh8vrtsqp7m2hd', bip353: 'maya@sonar.app', caps: ['marmot-dm', 'calls', 'payments'], media: ['voice', 'video'], met: 'today · in person', supporter: true },
    { id: 'luca', name: 'Luca', inRange: true, bars: 3, hint: 'Very close', detail: 'Same block · direct connection', angle: 335, r: 86,
      npub: 'npub1luc4q9c3uxe650pgh8vrtsw4j8mc7q0e2v9zk5xr3thl6f8s2a7dq8n3jd', caps: ['marmot-dm', 'calls'], media: ['voice', 'video'], met: 'today · in person' },
    { id: 'nettle', name: 'nettle', inRange: true, bars: 2, hint: 'Nearby', detail: '1 hop away · relayed through Maya', angle: 55, r: 118,
      npub: 'npub1nett1e6f8s2a7d4ynq9c3uxe650pgh8vrtsw4j8mc7q0e2v9zk5xrq2k7jd', caps: ['marmot-dm', 'calls'], media: ['voice'], met: '2 weeks ago · on mesh', supporter: true },
    { id: 'koi', name: 'koi_', inRange: true, bars: 1, hint: 'Edge of range', detail: '2 hops away · connection may drop', angle: 140, r: 150,
      npub: 'npub1koi8vrtsw4j8mc7q0e2v9zk5xr3thl6f8s2a7d4ynq9c3uxe650pgq5n8jd', caps: ['marmot-dm'], media: [], met: 'just now · on mesh' },
    { id: 'sofia', name: 'Sofia', inRange: false, bars: 0, hint: 'Out of range', detail: 'Met Saturday · reachable over internet', angle: 290, r: 168,
      npub: 'npub1sof1aq0e2v9zk5xr3thl6f8s2a7d4ynq9c3uxe650pgh8vrtsw4jq3m9hd', bip353: 'sofia@stacker.news', caps: ['marmot-dm', 'calls', 'payments'], media: ['voice', 'video'], met: 'Saturday · in person' },
    { id: 'tomas', name: 'Tomas', inRange: false, bars: 0, hint: 'Out of range', detail: 'Met last week · reachable over internet', angle: 22, r: 170,
      npub: 'npub1tom4s2a7d4ynq9c3uxe650pgh8vrtsw4j8mc7q0e2v9zk5xr3thl6q9k2jd', caps: ['marmot-dm'], media: [], met: 'last week · on mesh' },
  ],
  homeDMs: [
    { peer: 'maya', preview: 'find me by the coffee table', time: '18:05', unread: 0 },
    { peer: 'sofia', preview: 'done! check your downloads', time: 'Mon', unread: 0 },
    { peer: 'luca', preview: 'see you tomorrow', time: '12:30', unread: 0 },
    { peer: 'nettle', preview: 'thanks for relaying that', time: 'Tue', unread: 2 },
  ],
  // Private, named, end-to-end encrypted group chats — NOT public location channels.
  // members are peer ids; "you" is always implicitly a member.
  groups: [
    { id: 'lake', name: 'Lake crew', members: ['maya', 'luca', 'nettle'], preview: 'Maya: bringing the speaker', time: '17:58', unread: 2 },
    { id: 'trip', name: 'Weekend trip', members: ['maya', 'sofia', 'tomas'], preview: 'Sofia: booked the cabin!', time: 'Tue', unread: 0 },
  ],
  groupMsgs: {
    lake: [
      { author: 'Luca', text: 'lake later? water\u2019s unreal', time: '17:40', via: 'internet', reactions: [{ e: '🔥', who: ['Maya', 'Tomas'] }] },
      { author: 'nettle', text: 'i\u2019m down, leaving in 20', time: '17:43', via: 'internet' },
      { author: 'Maya', media: { type: 'image', shape: 'landscape', name: 'lake_now.jpg', cap: 'view from the dock' }, time: '17:55', via: 'internet' },
      { author: 'Maya', text: 'bringing the speaker', time: '17:58', via: 'internet' },
    ],
    trip: [
      { author: 'Sofia', text: 'ok who\u2019s actually coming this time', time: 'Tue', via: 'internet' },
      { mine: true, text: 'me + Maya for sure', time: 'Tue', via: 'internet', state: 'Delivered' },
      { author: 'Tomas', text: 'in. trains are cheap if we book now', time: 'Tue', via: 'internet' },
      { author: 'Sofia', text: 'booked the cabin!', time: 'Tue', via: 'internet' },
    ],
  },
  chMsgs: [
    { author: 'Luca', text: 'anyone at the lake later? water\u2019s perfect', time: '17:42', via: 'mesh' },
    { author: 'nettle', text: 'so much nicer than scrolling maps for plans', time: '17:44', via: 'internet' },
    { author: 'Luca', media: { type: 'image', shape: 'landscape', name: 'lake_now.jpg', cap: 'water\u2019s perfect rn' }, time: '17:50', via: 'mesh' },
    { author: 'Maya', text: 'in. I\u2019ll bring the speaker', time: '17:51', via: 'mesh' },
  ],
  dmMsgs: [
    { author: 'Maya', text: 'hey, did you make it to the meetup?', time: '18:02', via: 'mesh' },
    { mine: true, text: 'just got here \u2014 it\u2019s packed', time: '18:04', via: 'mesh', reactions: [{ e: '😂', who: ['Maya'] }] },
    { author: 'Maya', text: 'find me by the coffee table', time: '18:05', via: 'mesh' },
    { author: 'Maya', media: { type: 'image', shape: 'portrait', name: 'IMG_0421.jpg' }, time: '18:05', via: 'mesh' },
    { mine: true, media: { type: 'audio', name: 'vn-01', dur: '0:07' }, time: '18:06', via: 'mesh', state: 'Delivered' },
    { pay: true, amount: 5000, via: 'mesh', state: 'received', time: '18:06' },
  ],
  dmMsgsSofia: [
    { author: 'Sofia', text: 'the photos from saturday are up', time: 'Mon', via: 'internet' },
    { mine: true, text: 'these are great \u2014 send me the lake one?', time: 'Mon', via: 'internet', state: 'Delivered' },
    { author: 'Sofia', media: { type: 'video', shape: 'landscape', name: 'VID_0218.mp4', dur: '0:24' }, time: 'Mon', via: 'internet' },
    { author: 'Sofia', media: { type: 'file', name: 'Saturday set.zip', ext: 'ZIP', size: '48.2 MB' }, time: 'Mon', via: 'internet' },
    { author: 'Sofia', text: 'done! check your downloads', time: 'Mon', via: 'internet' },
  ],
  txns: [
    { dir: 'in', who: 'Maya', amount: 5000, via: 'mesh', state: 'received', time: '18:06' },
    { dir: 'out', who: 'Sofia', amount: 12000, via: 'internet', state: 'confirmed', time: 'Mon' },
    { dir: 'in', who: 'Luca', amount: 3000, via: 'mesh', state: 'received', time: 'Sun' },
    { dir: 'out', who: 'nettle', amount: 800, via: 'mesh', state: 'paid', time: 'Sat' },
    { dir: 'out', who: 'Tomas', amount: 25000, via: 'internet', state: 'failed', time: 'Fri' },
  ],
  safety: ['37294', '18056', '99214', '70338', '52181', '04967', '33852', '61490', '27745', '88130', '46021', '75913'],
  pubkey: 'npub1w4j8mc7q0e2v9zk5xr3thl6f8s2a7d4ynq9c3uxe650pgh8vrtsq4k9dj',
  nsec: 'nsec18gk4m2c7q0e2v9zk5xr3thl6f8s2a7d4ynq9c3uxe650pgh8vrtsq9w7xda',
  myFingerprint: 'a3f9 2c41 770e 5b2d',
  nicknames: ['quietfox', 'tram12', 'lakeswim', 'verdigris', 'morningstatic', 'papercrane', 'northpine', 'softsignal'],
};
