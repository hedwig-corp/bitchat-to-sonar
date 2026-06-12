// bitchat icon set — minimal SF-style line glyphs (24×24, stroke currentColor)

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
