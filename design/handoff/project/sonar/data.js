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
    { id: 'maya', name: 'Maya', inRange: true, bars: 3, hint: 'Right here', detail: 'Strong signal · a few meters away', angle: 210, r: 66 },
    { id: 'luca', name: 'Luca', inRange: true, bars: 3, hint: 'Very close', detail: 'Same block · direct connection', angle: 335, r: 86 },
    { id: 'nettle', name: 'nettle', inRange: true, bars: 2, hint: 'Nearby', detail: '1 hop away · relayed through Maya', angle: 55, r: 118 },
    { id: 'koi', name: 'koi_', inRange: true, bars: 1, hint: 'Edge of range', detail: '2 hops away · connection may drop', angle: 140, r: 150 },
    { id: 'sofia', name: 'Sofia', inRange: false, bars: 0, hint: 'Out of range', detail: 'Met Saturday · reachable over internet', angle: 290, r: 168 },
    { id: 'tomas', name: 'Tomas', inRange: false, bars: 0, hint: 'Out of range', detail: 'Met last week · reachable over internet', angle: 22, r: 170 },
  ],
  homeDMs: [
    { peer: 'maya', preview: 'find me by the coffee table', time: '18:05', unread: 0 },
    { peer: 'sofia', preview: 'done! check your downloads', time: 'Mon', unread: 0 },
    { peer: 'luca', preview: 'see you tomorrow', time: '12:30', unread: 0 },
    { peer: 'nettle', preview: 'thanks for relaying that', time: 'Tue', unread: 2 },
  ],
  chMsgs: [
    { author: 'Luca', text: 'anyone at the lake later? water\u2019s perfect', time: '17:42', via: 'mesh' },
    { author: 'nettle', text: 'so much nicer than scrolling maps for plans', time: '17:44', via: 'internet' },
    { author: 'Maya', text: 'in. I\u2019ll bring the speaker', time: '17:51', via: 'mesh' },
  ],
  dmMsgs: [
    { author: 'Maya', text: 'hey, did you make it to the meetup?', time: '18:02', via: 'mesh' },
    { mine: true, text: 'just got here \u2014 it\u2019s packed', time: '18:04', via: 'mesh' },
    { author: 'Maya', text: 'find me by the coffee table', time: '18:05', via: 'mesh' },
    { pay: true, amount: 5000, via: 'mesh', state: 'sealed', time: '18:06' },
  ],
  dmMsgsSofia: [
    { author: 'Sofia', text: 'the photos from saturday are up', time: 'Mon', via: 'internet' },
    { mine: true, text: 'these are great \u2014 send me the lake one?', time: 'Mon', via: 'internet', state: 'Delivered' },
    { author: 'Sofia', text: 'done! check your downloads', time: 'Mon', via: 'internet' },
  ],
  safety: ['37294', '18056', '99214', '70338', '52181', '04967', '33852', '61490', '27745', '88130', '46021', '75913'],
  pubkey: 'npub1w4j8mc7q0e2v9zk5xr3thl6f8s2a7d4ynq9c3uxe650pgh8vrtsq4k9dj',
  myFingerprint: 'a3f9 2c41 770e 5b2d',
  nicknames: ['quietfox', 'tram12', 'lakeswim', 'verdigris', 'morningstatic', 'papercrane', 'northpine', 'softsignal'],
};
