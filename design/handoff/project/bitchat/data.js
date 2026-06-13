// bitchat prototype — sample data
window.BC_DATA = {
  channels: [
    { id: 'centro', name: 'Lugano · Centro', sub: 'Public · 12 here now', preview: 'Maya: in. I\u2019ll bring the speaker', time: '17:51', unread: 3, count: 12 },
    { id: 'city', name: 'Lugano', sub: 'Public · 48 in range today', preview: 'City-wide · quieter', time: '', unread: 0, count: 48 },
  ],
  peers: [
    { id: 'maya', name: 'Maya', hint: 'Right here', detail: 'Strong signal · a few meters away', bars: 3 },
    { id: 'luca', name: 'Luca', hint: 'Very close', detail: 'Same block · direct connection', bars: 3 },
    { id: 'nettle', name: 'nettle', hint: 'Nearby', detail: '1 hop away · relayed through Maya', bars: 2 },
    { id: 'koi', name: 'koi_', hint: 'Edge of range', detail: '2 hops away · connection may drop', bars: 1 },
  ],
  homeDMs: [
    { peer: 'maya', preview: 'find me by the coffee table', time: '18:05', unread: 0 },
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
  ],
  safety: ['37294', '18056', '99214', '70338', '52181', '04967', '33852', '61490', '27745', '88130', '46021', '75913'],
  pubkey: 'npub1w4j8mc7q0e2v9zk5xr3thl6f8s2a7d4ynq9c3uxe650pgh8vrtsq4k9dj',
  myFingerprint: 'a3f9 2c41 770e 5b2d',
  nicknames: ['quietfox', 'tram12', 'lakeswim', 'verdigris', 'morningstatic', 'papercrane', 'northpine', 'softsignal'],
};
