"use strict";

// Small inline SVG icons standing in for the SF Symbols the macOS popover uses.
const ICONS = {
  serverRack: '<svg viewBox="0 0 16 16"><rect x="2" y="2.5" width="12" height="4.5" rx="1.2" fill="none" stroke="currentColor" stroke-width="1.4"/><rect x="2" y="9" width="12" height="4.5" rx="1.2" fill="none" stroke="currentColor" stroke-width="1.4"/><circle cx="4.6" cy="4.75" r=".8"/><circle cx="4.6" cy="11.25" r=".8"/><path d="M8 4.75h3.6M8 11.25h3.6" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/></svg>',
  refresh: '<svg viewBox="0 0 16 16"><path d="M13.2 8a5.2 5.2 0 1 1-1.6-3.75" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/><path d="M12.6 1.8v3.1H9.5" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  chevronRight: '<svg viewBox="0 0 16 16"><path d="M6 3.5 10.5 8 6 12.5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  chevronCircle: '<svg viewBox="0 0 16 16"><circle cx="8" cy="8" r="7.5"/><path d="M4.9 6.6 8 9.7l3.1-3.1" fill="none" stroke="var(--chevron-glyph)" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  desktop: '<svg viewBox="0 0 16 16"><rect x="1.8" y="2.5" width="12.4" height="8.5" rx="1.3" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M6 14h4M8 11v3" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>',
  network: '<svg viewBox="0 0 16 16"><circle cx="8" cy="8" r="6.2" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M1.8 8h12.4M8 1.8c2 2.1 2 10.3 0 12.4M8 1.8c-2 2.1-2 10.3 0 12.4" fill="none" stroke="currentColor" stroke-width="1.2"/></svg>',
  arrowDown: '<svg viewBox="0 0 16 16"><path d="M8 2.5v10M3.8 8.6 8 12.8l4.2-4.2" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  arrowUp: '<svg viewBox="0 0 16 16"><path d="M8 13.5v-10M3.8 7.4 8 3.2l4.2 4.2" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  warning: '<svg viewBox="0 0 16 16"><path d="M8 1.6 15 14H1z"/><path d="M8 6v4" stroke="#fff" stroke-width="1.6" stroke-linecap="round"/><circle cx="8" cy="11.9" r=".9" fill="#fff"/></svg>',
  info: '<svg viewBox="0 0 16 16"><circle cx="8" cy="8" r="6.3" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M8 7.2v4" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/><circle cx="8" cy="4.9" r=".9"/></svg>',
};
