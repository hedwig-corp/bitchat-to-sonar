// Sonar icon set — minimal SF-style line glyphs (24×24, stroke currentColor)

const BC_ICONS = {
  back: <path d="M14.5 4.5 7 12l7.5 7.5" />,
  chevron: <path d="M9.5 5l7 7-7 7" />,
  lock: <><rect x="5.5" y="10.5" width="13" height="9.5" rx="2.6" /><path d="M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5" /></>,
  plus: <path d="M12 5.5v13M5.5 12h13" />,
  send: <path d="M12 18.5v-13M6.5 11 12 5.5 17.5 11" />,
  search: <><circle cx="11" cy="11" r="5.6" /><path d="M15.4 15.4 20 20" /></>,
  pin: <><path d="M12 20.8s-6.3-5.3-6.3-10.2a6.3 6.3 0 0 1 12.6 0c0 4.9-6.3 10.2-6.3 10.2z" /><circle cx="12" cy="10.4" r="2.2" /></>,
  people: <><circle cx="9" cy="8.4" r="3.1" /><path d="M3.6 19.4c.6-3.3 2.8-5 5.4-5s4.8 1.7 5.4 5" /><circle cx="16.8" cy="9.4" r="2.5" /><path d="M16.6 14.5c2.1.4 3.5 2 3.9 4.7" /></>,
  mesh: <><circle cx="12" cy="12" r="1.7" fill="currentColor" stroke="none" /><path d="M8.7 8.7a4.7 4.7 0 0 0 0 6.6M15.3 8.7a4.7 4.7 0 0 1 0 6.6M6.2 6.2a8.2 8.2 0 0 0 0 11.6M17.8 6.2a8.2 8.2 0 0 1 0 11.6" /></>,
  globe: <><circle cx="12" cy="12" r="8.2" /><path d="M3.8 12h16.4M12 3.8c-2.7 2.5-4.1 5.2-4.1 8.2s1.4 5.7 4.1 8.2c2.7-2.5 4.1-5.2 4.1-8.2S14.7 6.3 12 3.8z" /></>,
  check: <path d="M5 12.8l4.3 4.3L19 7.4" />,
  shield: <path d="M12 3.4l7 2.7v5.2c0 4.4-2.9 7.4-7 9-4.1-1.6-7-4.6-7-9V6.1z" />,
  shieldCheck: <><path d="M12 3.4l7 2.7v5.2c0 4.4-2.9 7.4-7 9-4.1-1.6-7-4.6-7-9V6.1z" /><path d="M8.8 12.1l2.3 2.3 4.3-4.6" /></>,
  x: <path d="M6.5 6.5l11 11M17.5 6.5l-11 11" />,
  smile: <><circle cx="12" cy="12" r="8.2" /><circle cx="9.1" cy="10.2" r="1.1" fill="currentColor" stroke="none" /><circle cx="14.9" cy="10.2" r="1.1" fill="currentColor" stroke="none" /><path d="M8.7 14.2a4.5 4.5 0 0 0 6.6 0" /></>,
  navArrow: <path d="M20.4 3.6 3.8 10.2l6.6 3.4 3.4 6.6z" />,
  dice: <><rect x="4.2" y="4.2" width="15.6" height="15.6" rx="4" /><circle cx="8.8" cy="8.8" r="1.2" fill="currentColor" stroke="none" /><circle cx="15.2" cy="8.8" r="1.2" fill="currentColor" stroke="none" /><circle cx="12" cy="12" r="1.2" fill="currentColor" stroke="none" /><circle cx="8.8" cy="15.2" r="1.2" fill="currentColor" stroke="none" /><circle cx="15.2" cy="15.2" r="1.2" fill="currentColor" stroke="none" /></>,
  slash: <path d="M14.5 4.5l-5 15" />,
  rings: <><circle cx="12" cy="12" r="2" fill="currentColor" stroke="none" /><circle cx="12" cy="12" r="5.8" /><circle cx="12" cy="12" r="9.4" /></>,
  pencil: <path d="M16.8 4.6l2.6 2.6L8.6 18l-3.4.8.8-3.4z" />,
  key: <><circle cx="8.5" cy="12" r="3.4" /><path d="M11.9 12h8M17 12v2.8M19.9 12v2" /></>,
  inbox: <><rect x="4.5" y="5.5" width="15" height="14" rx="3" /><path d="M4.5 13.5h4l1.5 2.5h4l1.5-2.5h4" /></>,
  arrowOut: <path d="M8 16L16.5 7.5M9.5 7h7v7" />,
  faceid: <><path d="M4.5 8V6.5a2 2 0 0 1 2-2H8M16 4.5h1.5a2 2 0 0 1 2 2V8M19.5 16v1.5a2 2 0 0 1-2 2H16M8 19.5H6.5a2 2 0 0 1-2-2V16" /><circle cx="9.2" cy="10.4" r="0.9" fill="currentColor" stroke="none" /><circle cx="14.8" cy="10.4" r="0.9" fill="currentColor" stroke="none" /><path d="M9.6 14.4a3.4 3.4 0 0 0 4.8 0" /></>,
  drive: <><rect x="4.5" y="7.5" width="15" height="9.5" rx="2.5" /><circle cx="8" cy="14" r="0.9" fill="currentColor" stroke="none" /><path d="M4.5 11.5h15" /></>,
  data: <path d="M8 18.5V8.8M8 8.8 5.2 11.6M8 8.8l2.8 2.8M16 5.5v9.7M16 15.2l2.8-2.8M16 15.2l-2.8-2.8" />,
  list: <><path d="M9 6.5h11M9 12h11M9 17.5h11" /><circle cx="4.6" cy="6.5" r="1.2" fill="currentColor" stroke="none" /><circle cx="4.6" cy="12" r="1.2" fill="currentColor" stroke="none" /><circle cx="4.6" cy="17.5" r="1.2" fill="currentColor" stroke="none" /></>,
  moon: <path d="M19 13.8A7.6 7.6 0 1 1 10.2 5 6.1 6.1 0 0 0 19 13.8z" />,
  bell: <><path d="M12 4a5.5 5.5 0 0 1 5.5 5.5c0 3 .8 4.6 1.7 5.7H4.8c.9-1.1 1.7-2.7 1.7-5.7A5.5 5.5 0 0 1 12 4z" /><path d="M10 18.8a2.1 2.1 0 0 0 4 0" /></>,
  trash: <><path d="M5 7h14M10 7V5.6A1.6 1.6 0 0 1 11.6 4h.8A1.6 1.6 0 0 1 14 5.6V7" /><path d="M7 7l.8 12a1.8 1.8 0 0 0 1.8 1.7h4.8a1.8 1.8 0 0 0 1.8-1.7L17 7" /></>,
  info: <><circle cx="12" cy="12" r="8.2" /><path d="M12 11.2v5" /><circle cx="12" cy="8" r="1.1" fill="currentColor" stroke="none" /></>,
  compose: <><path d="M12 5.2H7.2A2.4 2.4 0 0 0 4.8 7.6v9a2.4 2.4 0 0 0 2.4 2.4h9a2.4 2.4 0 0 0 2.4-2.4V12" /><path d="M17.7 4.5l1.8 1.8-6.6 6.6-2.5.7.7-2.5z" /></>,
  coin: <><circle cx="12" cy="12" r="8.4" /><path d="M9.9 8.2h3a1.9 1.9 0 0 1 0 3.8h-3zM9.9 12h3.5a1.9 1.9 0 0 1 0 3.8H9.9zM9.9 8.2V16M11.4 6.6v1.6M11.4 16v1.6" /></>,
  bolt: <path d="M13 3 6 13.5h4.5L11 21l7-10.5h-4.5z" />,
  photo: <><rect x="4" y="5" width="16" height="14" rx="3" /><circle cx="9" cy="10" r="1.6" /><path d="M5 17.5 9.5 13l2.5 2.5 3-3 4 4" /></>,
  camera: <><path d="M4.5 8.5a2 2 0 0 1 2-2h1.2l1-1.6h6.6l1 1.6h1.2a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2z" /><circle cx="12" cy="12.5" r="3.2" /></>,
  videocam: <><rect x="3.5" y="7" width="12" height="10" rx="2.5" /><path d="M15.5 11l5-2.6v7.2l-5-2.6z" /></>,
  mic: <><rect x="9.2" y="3.4" width="5.6" height="11" rx="2.8" /><path d="M5.8 11.5a6.2 6.2 0 0 0 12.4 0M12 17.7V20.4M9 20.6h6" /></>,
  play: <path d="M7.5 5.5v13l11-6.5z" fill="currentColor" stroke="none" />,
  doc: <><path d="M6.5 3.5h7l5 5v12a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1v-16a1 1 0 0 1 1-1z" /><path d="M13.5 3.5V8.5h5" /></>,
  download: <><path d="M12 4v11M7.5 10.5 12 15l4.5-4.5" /><path d="M5 19.5h14" /></>,
};

function BCIcon({ name, size = 20, weight = 1.8, style, className }) {
  return (
    <svg
      width={size} height={size} viewBox="0 0 24 24"
      fill="none" stroke="currentColor" strokeWidth={weight}
      strokeLinecap="round" strokeLinejoin="round"
      style={style} className={className} aria-hidden="true"
    >{BC_ICONS[name] || null}</svg>
  );
}

Object.assign(window, { BCIcon });
