// Shared by panel.html and toast.html (inlined by cornercal.lua).
// No right-click menu: its Reload item would wipe the page's data.
document.addEventListener('contextmenu', (e) => e.preventDefault());
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const rgb = (h) => { h = String(h).replace('#', ''); return [0, 2, 4].map((i) => parseInt(h.substr(i, 2), 16) || 0); };

// The API returns Google's legacy palette; the web app draws the modern one.
// Snap to the nearest modern colour only when it is genuinely close.
const MODERN = ['#d50000', '#e67c73', '#f4511e', '#f6bf26', '#33b679', '#0b8043', '#039be5', '#3f51b5', '#7986cb', '#8e24aa', '#616161'];
function modern(h) {
  const c = rgb(h); let best = h, bd = 5000;
  for (const p of MODERN) {
    const q = rgb(p), d = (c[0] - q[0]) ** 2 + (c[1] - q[1]) ** 2 + (c[2] - q[2]) ** 2;
    if (d < bd) { bd = d; best = p; }
  }
  return best;
}
function lum(h) {
  const [r, g, b] = rgb(h).map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
const textOn = (bg) => (lum(bg) > 0.18 ? '#1f1f1f' : '#ffffff');

function hm(ms, withAmPm = true) {
  const d = new Date(ms); let h = d.getHours(); const m = d.getMinutes();
  const ap = h >= 12 ? 'pm' : 'am'; h = h % 12 || 12;
  return h + (m ? ':' + String(m).padStart(2, '0') : '') + (withAmPm ? ap : '');
}
function range(s, e) {
  const same = (new Date(s).getHours() >= 12) === (new Date(e).getHours() >= 12);
  return (same ? hm(s, false) : hm(s)) + ' – ' + hm(e);
}
function dur(ms) {
  const m = Math.max(0, Math.round(ms / 60000));
  return m >= 60 ? `${Math.floor(m / 60)}h${m % 60 ? ' ' + (m % 60) + 'm' : ''}` : `${m}m`;
}
