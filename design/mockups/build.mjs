// Generates the VinylCat mockup artboards (direction A · dark control-room).
// Run: node build.mjs  → writes *.dc.html + canvas.json in this folder.
import { writeFileSync } from 'node:fs';

const T = {
  bg: '#0e1012', panel: '#15181b', line: '#23272b', raised: '#2a2f34', muted: '#8a9096',
  text: '#f2efe8', sec: '#c9c5bb', green: '#7ee2a8', amber: '#f0b26b', blue: '#7cc4f5',
  orange: '#f28b5c', red: '#f06c6c', greenBg: '#12211a', amberBg: '#251d12', blueBg: '#122029',
  orangeBg: '#2a1a12', redBg: '#2a1414',
};
const cond = `font-family: 'Barlow Condensed', 'Arial Narrow', sans-serif;`;
const mono = `font-family: 'IBM Plex Mono', Menlo, monospace;`;
const label = (t, c = T.muted) => `<div style="font-size: 11px; letter-spacing: 0.14em; color: ${c};">${t}</div>`;
const icon = {
  mic: `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><rect x="9" y="3" width="6" height="11" rx="3"></rect><path d="M5 11a7 7 0 0 0 14 0M12 18v3"></path></svg>`,
  cam: `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8h3l2-3h6l2 3h3v11H4z"></path><circle cx="12" cy="13" r="3.5"></circle></svg>`,
  check: `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12l5 5L20 7"></path></svg>`,
  search: `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="11" cy="11" r="7"></circle><path d="M20 20l-4-4"></path></svg>`,
  chev: `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9l6 6 6-6"></path></svg>`,
  dot: `<svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="12" r="6"></circle></svg>`,
  dotEmpty: `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="6"></circle></svg>`,
  dash: `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><path d="M6 12h12"></path></svg>`,
  arrowDown: `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 5v14M6 13l6 6 6-6"></path></svg>`,
  cross: `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round"><path d="M6 6l12 12M18 6L6 18"></path></svg>`,
};
const dd = (t) => `<div style="display: flex; align-items: center; gap: 6px;"><div>${t}</div>${icon.chev}</div>`;

const head = `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
  <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Barlow+Condensed:wght@500;700&family=IBM+Plex+Mono:wght@400;500&display=swap">
  <style>
    body { margin: 0; background: ${T.bg}; color: ${T.text}; ${mono} }
    a { color: ${T.green}; } a:hover { color: #a5f0c4; }
  </style>
</helmet>`;
const tail = `</x-dc>
</body>
</html>
`;

// ---------- shared chrome ----------
const tab = (t, active) => `<div style="padding: 6px 12px; font-size: 13px; letter-spacing: 0.12em; color: ${active ? T.text : T.muted}; border-bottom: 2px solid ${active ? T.green : 'transparent'};">${t}</div>`;
const topBar = ({ active = 'SCAN', format = '7" SINGLES', listening = true, auto = true }) => `
  <div style="height: 56px; display: flex; align-items: center; gap: 24px; padding: 0 24px; border-bottom: 1px solid ${T.line}; box-sizing: border-box;">
    <div style="${cond} font-weight: 700; font-size: 26px; letter-spacing: 0.06em; color: ${T.text};">VINYLCAT</div>
    <div style="display: flex; gap: 4px;">${tab('SCAN', active === 'SCAN')}${tab('LIBRARY', active === 'LIBRARY')}${tab('REVIEW · 3', active === 'REVIEW')}${tab('SETTINGS', active === 'SETTINGS')}</div>
    <div style="flex-grow: 1;"></div>
    <div style="display: flex; align-items: center; gap: 8px; padding: 6px 12px; border: 1px solid ${auto ? T.green : T.muted}; color: ${auto ? T.green : T.muted}; font-size: 13px; letter-spacing: 0.12em;">
      <div style="width: 8px; height: 8px; background: ${auto ? T.green : T.muted}; border-radius: 50%;"></div>
      <div>${auto ? 'AUTO MODE' : 'PAUSED'}</div>
    </div>
    <div style="font-size: 13px; color: ${T.muted};">FORMAT</div>
    <div style="${cond} font-weight: 700; font-size: 22px; color: ${T.text};">${format}</div>
    <div style="width: 1px; height: 24px; background: ${T.line};"></div>
    <div style="display: flex; align-items: center; gap: 6px; font-size: 13px; color: ${listening ? T.green : T.muted};">${icon.mic}<div>${listening ? 'LISTENING' : 'MIC OFF'}</div></div>
  </div>`;
const bottomBar = (hint, count = 47) => `
  <div style="height: 44px; display: flex; align-items: center; gap: 28px; padding: 0 24px; border-top: 1px solid ${T.line}; font-size: 12px; color: ${T.muted}; box-sizing: border-box;">
    <div style="display: flex; align-items: center; gap: 6px;">${icon.cam}${dd('FACETIME HD')}</div>
    <div>${hint}</div>
    <div style="flex-grow: 1;"></div>
    <div>SESSION 3 · ${count} RECORDS</div>
  </div>`;

// ---------- scan pieces ----------
const vinylGhost = (size = 420, color = '#4a525a') => `
  <div style="width: ${size}px; height: ${size}px; border: 3px dashed ${color}; border-radius: 50%; display: flex; align-items: center; justify-content: center;">
    <div style="width: ${Math.round(size * 0.36)}px; height: ${Math.round(size * 0.36)}px; border: 3px dashed ${color}; border-radius: 50%;"></div>
  </div>`;
const sleeveGhost = (w = 520, color = '#4a525a') => `
  <div style="width: ${w}px; height: ${w}px; border: 3px dashed ${color}; display: flex; flex-direction: column; justify-content: flex-end; padding: 28px; box-sizing: border-box; gap: 10px;">
    <div style="width: 60%; height: 28px; border: 2px dashed ${color};"></div>
    <div style="width: 40%; height: 18px; border: 2px dashed ${color};"></div>
  </div>`;
const ring = (pct, color, text) => {
  // quarter-based sketch of a progress ring
  const sides = ['top', 'right', 'bottom', 'left'];
  const filled = Math.round(pct * 4);
  const css = sides.map((s, i) => `border-${s}-color: ${i < filled ? color : T.raised};`).join(' ');
  return `<div style="position: absolute; top: 20px; right: 20px; width: 84px; height: 84px; border-radius: 50%; border: 7px solid ${T.raised}; ${css} display: flex; align-items: center; justify-content: center; font-size: 11px; letter-spacing: 0.1em; color: ${color}; box-sizing: border-box;">${text}</div>`;
};
const camTag = (t) => `<div style="position: absolute; top: 20px; left: 20px; font-size: 12px; color: ${T.muted}; letter-spacing: 0.1em;">${t}</div>`;
const banner = (color, rows) => `
  <div style="position: absolute; left: 0; right: 0; bottom: 0; background: rgba(14,16,18,0.94); border-top: 4px solid ${color}; padding: 20px 28px; display: flex; flex-direction: column; gap: 8px; box-sizing: border-box;">${rows}</div>`;
const state = (color, t, meta = '') => `
  <div style="display: flex; align-items: center; gap: 14px;">
    <div style="${cond} font-weight: 700; font-size: 22px; letter-spacing: 0.14em; color: ${color};">${t}</div>
    ${meta ? `<div style="font-size: 12px; color: ${T.muted};">${meta}</div>` : ''}
  </div>`;
const big = (t, size = 64) => `<div style="${cond} font-weight: 700; font-size: ${size}px; line-height: 1; color: ${T.text};">${t}</div>`;
const sub = (t, color = T.sec) => `<div style="${cond} font-weight: 500; font-size: 30px; line-height: 1.1; color: ${color};">${t}</div>`;
const small = (t, color = T.muted) => `<div style="font-size: 13px; color: ${color};">${t}</div>`;

const stripItem = (name, meta, color = T.text, metaColor = T.muted) => `
  <div style="display: flex; gap: 12px; align-items: center;">
    <div style="width: 52px; height: 52px; background: ${T.raised}; flex-shrink: 0;"></div>
    <div style="display: flex; flex-direction: column; gap: 2px; min-width: 0;"><div style="font-size: 13px; color: ${color};">${name}</div><div style="font-size: 11px; color: ${metaColor};">${meta}</div></div>
  </div>`;
const sessionStrip = `
  <div style="padding: 16px 20px 8px;">${label('THIS SESSION · LAST 4')}</div>
  <div style="display: flex; flex-direction: column; gap: 10px; padding: 0 20px;">
    ${stripItem('The Specials — Ghost Town', '1981 · 7" · 2 shots · synced')}
    ${stripItem('Blondie — Heart Of Glass', '1979 · 7" · 2 shots · synced')}
    ${stripItem('Unknown — label shot', 'REVIEW QUEUE · 1 shot', T.red, T.red)}
    ${stripItem('Dexys — Geno', '1980 · 7" · 2 shots · synced')}
  </div>`;
const railMeters = (review = '3') => `
  <div style="padding: 16px 20px; border-top: 1px solid ${T.line}; display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 8px;">
    <div style="display: flex; flex-direction: column; gap: 2px;">${label('DISCOGS', T.muted)}<div style="font-size: 16px; color: ${T.text};">14/60</div></div>
    <div style="display: flex; flex-direction: column; gap: 2px;">${label('LLM COST')}<div style="font-size: 16px; color: ${T.text};">$0.04</div></div>
    <div style="display: flex; flex-direction: column; gap: 2px;">${label('REVIEW')}<div style="font-size: 16px; color: ${T.red};">${review}</div></div>
  </div>`;
const railTop = (bg, rows) => `<div style="padding: 22px 20px; background: ${bg}; border-bottom: 1px solid ${T.line}; display: flex; flex-direction: column; gap: 8px;">${rows}</div>`;

const scan = ({ preview, rail, hint, format, count = 47, review = '3' }) => `${head}
<div style="width: 1440px; height: 900px; background: ${T.bg}; display: flex; flex-direction: column; box-sizing: border-box;">
  ${topBar({ format })}
  <div style="flex-grow: 1; display: flex; min-height: 0;">
    <div style="flex-grow: 1; position: relative; background: ${T.panel}; display: flex; align-items: center; justify-content: center; overflow: hidden;">
      <div style="width: 1080px; height: 700px; background: repeating-linear-gradient(135deg, #1a1e22 0 14px, #171a1d 14px 28px); border: 1px solid ${T.raised}; position: relative; display: flex; align-items: center; justify-content: center; overflow: hidden;">
        ${preview}
      </div>
    </div>
    <div style="width: 340px; border-left: 1px solid ${T.line}; display: flex; flex-direction: column; box-sizing: border-box;">
      ${rail}
      <div style="flex-grow: 1;"></div>
      ${railMeters(review)}
    </div>
  </div>
  ${bottomBar(hint, count)}
</div>
${tail}`;

const HINT = `VOICE · "capture" · "flip" · "skip" · "review" · "forty-fives" · "albums" · "undo"`;

// 1 · Armed
const Main = scan({
  format: '7" SINGLES',
  preview: `
    ${vinylGhost(380, '#33393f')}
    ${camTag('FACETIME HD · 1080p · LIVE')}
    ${ring(0, T.muted, 'READY')}
    ${banner(T.muted, state(T.muted, 'ARMED', 'record #48 · scene empty') + big('HOLD UP A RECORD') + small('Auto-captures when the image is steady and sharp · say "capture" to force · cover or label, either works'))}`,
  rail: railTop(T.panel, label('NEXT') + big('WAITING', 40) + small('Show the cover first. If there is no picture sleeve, hold the label close to the camera.')) + sessionStrip,
  hint: HINT,
});

// 2 · Reading
const ocrBox = (t, x, y, w) => `<div style="position: absolute; left: ${x}px; top: ${y}px; width: ${w}px; border: 2px solid ${T.amber}; padding: 4px 6px; font-size: 12px; color: ${T.amber}; background: rgba(14,16,18,0.6);">${t}</div>`;
const ScanReading = scan({
  format: '7" SINGLES',
  preview: `
    ${vinylGhost(420, '#5a6270')}
    ${ocrBox('POLYDOR', 470, 190, 110)}
    ${ocrBox('POSP 113', 470, 224, 110)}
    ${ocrBox('GOING UNDERGROUND', 420, 400, 210)}
    ${ocrBox('THE JAM', 470, 434, 110)}
    ${ocrBox('45 RPM · A', 640, 300, 110)}
    ${camTag('CAPTURED · 14:32:07 · SAVED photos/0048-label-a.jpg')}
    ${ring(1, T.amber, 'SHOT')}
    ${banner(T.amber, state(T.amber, 'READING', 'barcode none · OCR 6 lines · 0.9 s') + big('READING THE LABEL…') + `
      <div style="display: flex; gap: 24px; align-items: center;">
        <div style="width: 420px; height: 8px; background: ${T.raised};"><div style="width: 62%; height: 8px; background: ${T.amber};"></div></div>
        ${small('GPT-5.6 Luna · then Discogs', T.sec)}
      </div>`)}`,
  rail: railTop(T.amberBg, label('PIPELINE · RECORD #48', T.amber) + `
    <div style="display: flex; flex-direction: column; gap: 8px; font-size: 13px;">
      <div style="display: flex; gap: 10px; color: ${T.green};"><div>${icon.check}</div><div>Capture · sharp 0.91 · steady 640 ms</div></div>
      <div style="display: flex; gap: 10px; color: ${T.muted};"><div>${icon.dash}</div><div>Barcode · none (label shot)</div></div>
      <div style="display: flex; gap: 10px; color: ${T.green};"><div>${icon.check}</div><div>OCR · 6 lines · catno POSP 113</div></div>
      <div style="display: flex; gap: 10px; color: ${T.amber};"><div>${icon.dot}</div><div>Vision model · reading</div></div>
      <div style="display: flex; gap: 10px; color: ${T.muted};"><div>${icon.dotEmpty}</div><div>Discogs search · rank</div></div>
    </div>`) + sessionStrip,
  hint: HINT,
});

// 3 · Matched
const ScanMatched = scan({
  format: '7" SINGLES', count: 48,
  preview: `
    ${vinylGhost(420, '#5a6270')}
    ${camTag('CAPTURED · 14:32:07')}
    ${ring(1, T.green, 'OK')}
    ${banner(T.green, state(T.green, 'MATCHED', '0.94 · DISCOGS r2413807 · 6.8 s total') + big('THE JAM — GOING UNDERGROUND') + sub('1980 · 7" · POLYDOR POSP 113 · UK'))}`,
  rail: railTop(T.greenBg, label('SAVED · RECORD #48', T.green) + `
    <div style="display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 6px 12px; font-size: 13px;">
      <div style="color: ${T.muted};">B-side</div><div>Dreams Of Children</div>
      <div style="color: ${T.muted};">Genre</div><div>Rock · Mod</div>
      <div style="color: ${T.muted};">Value</div><div>£4 – £9 · median £6</div>
      <div style="color: ${T.muted};">Discogs</div><div style="color: ${T.green};">sync queued</div>
      <div style="color: ${T.muted};">Photo</div><div>label A · 1600px</div>
    </div>`) + railTop(T.panel, label('NEXT SHOT') + big('SHOW ME THE B-SIDE', 36) + small('say "skip" · "done" · "add photo"')) + sessionStrip,
  hint: `VOICE · "skip" · "done" · "add photo" · "flip" · "undo" · "review"`,
});

// 4 · Ambiguous
const cand = (n, t, m, size = 30) => `
  <div style="display: flex; gap: 18px; align-items: baseline;">
    <div style="${cond} font-weight: 700; font-size: 44px; line-height: 1; color: ${T.orange}; width: 40px; flex-shrink: 0;">${n}</div>
    <div style="display: flex; flex-direction: column; gap: 4px; min-width: 0;">
      <div style="${cond} font-weight: 700; font-size: ${size}px; line-height: 1; color: ${T.text};">${t}</div>
      <div style="font-size: 13px; color: ${T.muted};">${m}</div>
    </div>
  </div>`;
const ScanAmbiguous = scan({
  format: '7" SINGLES',
  preview: `
    <div style="position: absolute; top: 90px; left: 0; right: 0; display: flex; justify-content: center;">${vinylGhost(300, '#5a6270')}</div>
    ${camTag('CAPTURED · 14:32:07')}
    ${ring(1, T.orange, '3')}
    ${banner(T.orange, state(T.orange, '3 MATCHES', 'The Jam — Going Underground · say ONE, TWO, THREE or NONE') + `
      <div style="display: flex; flex-direction: column; gap: 12px; padding-top: 4px;">
        ${cand('1', 'POLYDOR POSP 113 · UK · 1980', '7" · paper sleeve · 0.71')}
        ${cand('2', 'POLYDOR 2059 227 · GERMANY · 1980', '7" · picture sleeve · 0.66')}
        ${cand('3', 'POLYDOR POSPX 113 · UK · 1980', '12" · 0.41')}
      </div>`)}`,
  rail: railTop(T.orangeBg, label('NEEDS A DECISION', T.orange) + big('ONE, TWO OR THREE?', 36) + small('Or flip it — the B-side label usually settles it: say "flip" or just show me the other side.')) + railTop(T.panel, label('WHAT I READ') + `
    <div style="font-size: 13px; color: ${T.sec}; line-height: 1.5;">Polydor · POSP 113 · "Going Underground" · The Jam · 45 RPM · side A<br><span style="color: ${T.muted};">country and sleeve type not visible on a label shot</span></div>`) + sessionStrip,
  hint: `VOICE · "one" · "two" · "three" · "none" · "flip" · "review"`,
});

// 5 · Need label
const ScanNeedLabel = scan({
  format: 'ALBUMS', count: 48,
  preview: `
    ${sleeveGhost(520, '#5a6270')}
    ${camTag('CAPTURED · 14:35:41 · COVER')}
    ${ring(0.25, T.blue, 'LABEL')}
    ${banner(T.blue, state(T.blue, 'SHOW ME THE LABEL', 'cover read but no confident Discogs match · 0.52') + big('THE FALL — ?', 56) + small('Cover text was thin — the label carries the catalogue number. Slide the record out and hold side A up to the camera.', T.sec))}`,
  rail: railTop(T.blueBg, label('RECORD #49 · SHOTS 1/3', T.blue) + `
    <div style="display: flex; flex-direction: column; gap: 8px; font-size: 13px;">
      <div style="display: flex; gap: 10px; color: ${T.green};"><div>${icon.check}</div><div>Front cover · saved</div></div>
      <div style="display: flex; gap: 10px; color: ${T.blue};"><div>${icon.dot}</div><div>Label side A · waiting</div></div>
      <div style="display: flex; gap: 10px; color: ${T.muted};"><div>${icon.dotEmpty}</div><div>Back cover</div></div>
    </div>`) + railTop(T.panel, label('BEST GUESS SO FAR') + `<div style="font-size: 13px; color: ${T.sec}; line-height: 1.5;">Artist: The Fall · title unclear · 12 candidates on Discogs.<br><span style="color: ${T.muted};">say "review" to park it and move on</span></div>`) + sessionStrip,
  hint: `VOICE · "capture" · "review" · "skip" · "undo"`,
});

// 6 · Awaiting shot — double album
const shotRow = (st, t, c) => `<div style="display: flex; gap: 10px; color: ${c};"><div style="width: 14px;">${st}</div><div>${t}</div></div>`;
const ScanAwaitingShot = scan({
  format: 'ALBUMS', count: 49,
  preview: `
    ${vinylGhost(320, '#33393f')}
    ${camTag('FACETIME HD · LIVE')}
    ${ring(0.5, T.blue, 'HOLD')}
    ${banner(T.blue, state(T.blue, 'NEXT SHOT · 5 OF 6', 'The Clash — London Calling · 1979 · 2×LP · CBS CLASH 3 · matched 0.97') + big('DISC 2 · SIDE C LABEL') + small('Double album detected from Discogs (2 × LP, gatefold). say "skip" to move on · "done" to finish this record · "undo" to retake the last shot', T.sec))}`,
  rail: railTop(T.blueBg, label('RECORD #50 · SHOTS 4/6', T.blue) + `
    <div style="display: flex; flex-direction: column; gap: 8px; font-size: 13px;">
      ${shotRow(icon.check, 'Front cover', T.green)}
      ${shotRow(icon.check, 'Back cover', T.green)}
      ${shotRow(icon.check, 'Gatefold inside', T.green)}
      ${shotRow(icon.check, 'Disc 1 · labels A + B', T.green)}
      ${shotRow(icon.dot, 'Disc 2 · side C label', T.blue)}
      ${shotRow(icon.dotEmpty, 'Disc 2 · side D label', T.muted)}
    </div>`) + railTop(T.panel, label('SHOTS SO FAR') + `
    <div style="display: flex; gap: 8px;">
      <div style="width: 60px; height: 60px; background: ${T.raised};"></div>
      <div style="width: 60px; height: 60px; background: ${T.raised};"></div>
      <div style="width: 60px; height: 60px; background: ${T.raised};"></div>
      <div style="width: 60px; height: 60px; background: ${T.raised};"></div>
      <div style="width: 60px; height: 60px; border: 2px dashed ${T.blue}; box-sizing: border-box;"></div>
    </div>`) + sessionStrip,
  hint: `VOICE · "skip" · "done" · "undo" · "add photo" · "gatefold" · "disc two"`,
});

// 7 · Not found → review
const ScanNotFound = scan({
  format: '7" SINGLES', count: 50, review: '4',
  preview: `
    ${vinylGhost(420, '#5a6270')}
    ${camTag('CAPTURED · 14:38:12 · SAVED photos/0051-label-a.jpg')}
    ${ring(1, T.red, icon.cross)}
    ${banner(T.red, state(T.red, 'NOT FOUND', 'added to review queue · now 4 waiting · photo kept') + big('SUNSHINE SUPERMAN — DONOVAN?', 56) + small('Read "Pye" and "7N" but the catalogue number was blurred · 0 confident Discogs hits · say "again" to retake, "label" if that was the cover, or just show me the next record', T.sec))}`,
  rail: railTop(T.redBg, label('PARKED · RECORD #51', T.red) + `
    <div style="display: flex; gap: 12px; align-items: center;">
      <div style="width: 72px; height: 72px; background: ${T.raised}; flex-shrink: 0;"></div>
      <div style="font-size: 13px; color: ${T.sec}; line-height: 1.5;">You can finish it later in Review, by voice, with the photo on screen.</div>
    </div>`) + railTop(T.panel, label('WHAT I READ') + `<div style="font-size: 13px; color: ${T.sec}; line-height: 1.5;">PYE · 7N.1?9?? · SUNSHINE SUPERMAN · DONOVAN · 45<br><span style="color: ${T.muted};">tip: tilt the label away from the window glare</span></div>`) + sessionStrip,
  hint: `VOICE · "again" · "label" · "review" · "skip"`,
});

// ---------- Library ----------
const chip = (t, active) => `<div style="padding: 6px 12px; font-size: 12px; letter-spacing: 0.08em; border: 1px solid ${active ? T.green : T.line}; color: ${active ? T.green : T.sec};">${t}</div>`;
const rows = [
  ['The Jam', 'Going Underground', '1980', '7"', 'Polydor · POSP 113', '£6', '2/2', 'synced', true],
  ['The Specials', 'Ghost Town', '1981', '7"', '2 Tone · CHS TT 17', '£8', '2/2', 'synced'],
  ['Blondie', 'Heart Of Glass', '1979', '7"', 'Chrysalis · CHS 2275', '£4', '2/2', 'synced'],
  ['Dexys Midnight Runners', 'Geno', '1980', '7"', 'Late Night Feelings · R 6033', '£3', '2/2', 'synced'],
  ['The Clash', 'London Calling', '1979', '2×LP', 'CBS · CLASH 3', '£45', '6/6', 'synced'],
  ['The Fall', 'Hex Enduction Hour', '1982', 'LP', 'Kamera · KAM 005', '£60', '1/3', 'incomplete'],
  ['Donovan', 'Sunshine Superman', '1966', '7"', 'Pye · —', '—', '1/2', 'review'],
  ['New Order', 'Blue Monday', '1983', '12"', 'Factory · FAC 73', '£25', '2/2', 'synced'],
  ['Joy Division', 'Unknown Pleasures', '1979', 'LP', 'Factory · FACT 10', '£120', '3/3', 'pending'],
  ['Grace Jones', 'Pull Up To The Bumper', '1981', '12"', 'Island · 12WIP 6696', '£12', '2/2', 'synced'],
  ['Kraftwerk', 'The Model', '1981', '7"', 'EMI · EMI 5207', '£5', '2/2', 'synced'],
  ['Talking Heads', 'Remain In Light', '1980', 'LP', 'Sire · SRK 6095', '£30', '3/3', 'synced'],
];
const syncColor = { synced: T.green, pending: T.muted, incomplete: T.amber, review: T.red };
const tr = ([a, t, y, f, l, v, s, sy, sel]) => `
  <div style="display: grid; grid-template-columns: 170px minmax(0, 1fr) 50px 50px minmax(0, 1fr) 60px 50px 80px; gap: 12px; padding: 10px 16px; font-size: 13px; background: ${sel ? T.greenBg : 'transparent'}; border-bottom: 1px solid ${T.line}; color: ${T.text};">
    <div>${a}</div><div>${t}</div><div style="color: ${T.muted};">${y}</div><div>${f}</div><div style="color: ${T.sec};">${l}</div><div>${v}</div><div style="color: ${s.startsWith('1/') ? T.amber : T.muted};">${s}</div><div style="color: ${syncColor[sy]};">${sy.toUpperCase()}</div>
  </div>`;
const Library = `${head}
<div style="width: 1440px; height: 900px; background: ${T.bg}; display: flex; flex-direction: column; box-sizing: border-box;">
  ${topBar({ active: 'LIBRARY', format: '—', listening: false, auto: false })}
  <div style="flex-grow: 1; display: flex; min-height: 0;">
    <div style="flex-grow: 1; display: flex; flex-direction: column; min-width: 0;">
      <div style="display: flex; align-items: center; gap: 12px; padding: 16px 24px; border-bottom: 1px solid ${T.line};">
        <div style="display: flex; align-items: center; gap: 10px; width: 260px; padding: 8px 12px; border: 1px solid ${T.raised}; color: ${T.muted}; font-size: 13px;">${icon.search}<div>Search artist, title, label, cat no…</div></div>
        ${chip('ALL · 1,204', true)}${chip('7" · 611')}${chip('12" · 143')}${chip('LP · 450')}${chip('INCOMPLETE · 5')}${chip('REVIEW · 3')}
      </div>
      <div style="display: grid; grid-template-columns: 170px minmax(0, 1fr) 50px 50px minmax(0, 1fr) 60px 50px 80px; gap: 12px; padding: 10px 16px; font-size: 11px; letter-spacing: 0.12em; color: ${T.muted}; border-bottom: 1px solid ${T.line};">
        <div>ARTIST</div><div>TITLE</div><div>YEAR</div><div>FMT</div><div>LABEL · CAT NO.</div><div>VALUE</div><div>SHOTS</div><div style="display: flex; align-items: center; gap: 4px;"><div>ADDED</div>${icon.arrowDown}</div>
      </div>
      <div style="flex-grow: 1; overflow: hidden;">${rows.map(tr).join('')}</div>
      <div style="display: flex; gap: 28px; align-items: center; padding: 0 24px; height: 44px; border-top: 1px solid ${T.line}; font-size: 12px; color: ${T.muted};">
        <div>1,204 RECORDS · EST. VALUE £9,840 (DISCOGS MEDIAN)</div>
        <div style="flex-grow: 1;"></div>
        <div style="color: ${T.sec};">EXPORT CSV</div><div style="color: ${T.sec};">OPEN PHOTOS FOLDER</div>
      </div>
    </div>
    <div style="width: 400px; border-left: 1px solid ${T.line}; display: flex; flex-direction: column; gap: 18px; padding: 22px 20px; box-sizing: border-box; overflow: hidden;">
      <div style="display: flex; gap: 8px;">
        <div style="width: 84px; height: 84px; background: ${T.raised};"></div>
        <div style="width: 84px; height: 84px; background: ${T.raised};"></div>
        <div style="width: 84px; height: 84px; background: ${T.raised}; opacity: 0.5;"></div>
        <div style="width: 84px; height: 84px; border: 1px dashed ${T.raised}; box-sizing: border-box; display: flex; align-items: center; justify-content: center; font-size: 11px; color: ${T.muted};">+ SHOT</div>
      </div>
      ${label('LABEL A · LABEL B · DISCOGS ART')}
      <div style="display: flex; flex-direction: column; gap: 4px;">
        ${big('GOING UNDERGROUND', 40)}
        ${sub('THE JAM', T.sec)}
      </div>
      <div style="display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 6px 12px; font-size: 13px;">
        <div style="color: ${T.muted};">Format</div><div>7" · 45 RPM · single</div>
        <div style="color: ${T.muted};">Label</div><div>Polydor · POSP 113</div>
        <div style="color: ${T.muted};">Released</div><div>1980 · UK</div>
        <div style="color: ${T.muted};">Genre</div><div>Rock · Mod, Punk</div>
        <div style="color: ${T.muted};">Value</div><div>£4 – £9 · median £6 · 212 for sale</div>
        <div style="color: ${T.muted};">Discogs</div><div style="color: ${T.green};">r2413807 · in collection</div>
        <div style="color: ${T.muted};">Added</div><div>6 Sep 2026 · session 3</div>
      </div>
      ${label('TRACKLIST')}
      <div style="display: flex; flex-direction: column; gap: 4px; font-size: 13px;">
        <div style="display: flex; justify-content: space-between;"><div>A · Going Underground</div><div style="color: ${T.muted};">2:58</div></div>
        <div style="display: flex; justify-content: space-between;"><div>B · Dreams Of Children</div><div style="color: ${T.muted};">3:04</div></div>
      </div>
      ${label('NOTES')}
      <div style="font-size: 13px; color: ${T.muted}; border: 1px dashed ${T.raised}; padding: 10px;">Condition, pressing notes, where it came from…</div>
      <div style="flex-grow: 1;"></div>
      <div style="display: flex; gap: 16px; font-size: 12px; color: ${T.sec};"><div>RE-IDENTIFY</div><div>OPEN ON DISCOGS</div><div style="color: ${T.red};">DELETE</div></div>
    </div>
  </div>
</div>
${tail}`;

// ---------- Review queue ----------
const qItem = (n, t, m, active) => `
  <div style="display: flex; gap: 12px; align-items: center; padding: 12px 16px; background: ${active ? T.redBg : 'transparent'}; border-bottom: 1px solid ${T.line};">
    <div style="width: 48px; height: 48px; background: ${T.raised}; flex-shrink: 0;"></div>
    <div style="display: flex; flex-direction: column; gap: 2px; min-width: 0;"><div style="font-size: 13px; color: ${T.text};">${n} · ${t}</div><div style="font-size: 11px; color: ${T.muted};">${m}</div></div>
  </div>`;
const Review = `${head}
<div style="width: 1440px; height: 900px; background: ${T.bg}; display: flex; flex-direction: column; box-sizing: border-box;">
  ${topBar({ active: 'REVIEW', format: '—', listening: true, auto: false })}
  <div style="flex-grow: 1; display: flex; min-height: 0;">
    <div style="width: 320px; border-right: 1px solid ${T.line}; display: flex; flex-direction: column;">
      <div style="padding: 16px 16px 8px;">${label('REVIEW QUEUE · 3 + 5 INCOMPLETE')}</div>
      ${qItem('#51', 'Sunshine Superman?', 'not found · label shot · 14:38', true)}
      ${qItem('#45', 'Unknown', 'not found · label shot · 14:21')}
      ${qItem('#31', 'Pretenders — ?', 'ambiguous · none chosen · 13:58')}
      <div style="padding: 16px 16px 8px;">${label('INCOMPLETE SHOTS')}</div>
      ${qItem('#49', 'The Fall — Hex Enduction Hour', '1/3 shots · needs label + back')}
      ${qItem('#22', 'Roxy Music — Avalon', '2/3 shots · needs back cover')}
      ${qItem('#19', 'Kate Bush — Hounds Of Love', '2/3 shots · needs label')}
      ${qItem('#12', 'Siouxsie — Hong Kong Garden', '1/2 shots · needs B-side')}
      ${qItem('#7', 'Wire — Chairs Missing', '1/3 shots · needs label + back')}
    </div>
    <div style="flex-grow: 1; display: flex; flex-direction: column; min-width: 0;">
      <div style="flex-grow: 1; display: flex; gap: 24px; padding: 24px; min-height: 0;">
        <div style="width: 520px; height: 520px; background: repeating-linear-gradient(135deg, #1a1e22 0 14px, #171a1d 14px 28px); border: 1px solid ${T.raised}; position: relative; display: flex; align-items: center; justify-content: center; flex-shrink: 0;">
          ${vinylGhost(400, '#5a6270')}
          ${camTag('photos/0051-label-a.jpg · 14:38:12')}
          <div style="position: absolute; left: 16px; bottom: 16px; display: flex; gap: 8px;"><div style="width: 56px; height: 56px; border: 2px solid ${T.red}; box-sizing: border-box; background: ${T.raised};"></div><div style="width: 56px; height: 56px; border: 1px dashed ${T.raised}; box-sizing: border-box; display: flex; align-items: center; justify-content: center; font-size: 10px; color: ${T.muted};">+ SHOT</div></div>
        </div>
        <div style="flex-grow: 1; display: flex; flex-direction: column; gap: 18px; min-width: 0;">
          ${state(T.red, 'NOT FOUND · #51', 'captured 14:38 · session 3')}
          ${label('WHAT I READ')}
          <div style="font-size: 13px; color: ${T.sec}; line-height: 1.6; padding: 12px; border: 1px solid ${T.line};">PYE · 7N.1?9?? · SUNSHINE SUPERMAN · DONOVAN · 45 RPM · MADE IN GT. BRITAIN<br><span style="color: ${T.muted};">catalogue number partly unreadable · 0 confident hits with format 7"</span></div>
          ${label('TELL ME MORE — SPEAK OR TYPE', T.green)}
          <div style="display: flex; align-items: center; gap: 12px; padding: 14px 16px; border: 1px solid ${T.green}; font-size: 15px; color: ${T.text};">
            <div style="color: ${T.green};">${icon.mic}</div>
            <div>"it's the nineteen sixty-six Pye seven inch, catalogue seven N one seven two four one"</div>
          </div>
          ${label('CANDIDATES · SAY ONE, TWO, THREE OR NONE', T.orange)}
          <div style="display: flex; flex-direction: column; gap: 10px;">
            ${cand('1', 'PYE 7N 17241 · UK · 1966', '7" · Sunshine Superman / The Trip · 0.88', 24)}
            ${cand('2', 'PYE 7N 17241 · UK · 1966 · RE', '7" · reissue · 0.61', 24)}
            ${cand('3', 'EPIC 5-10045 · US · 1966', '7" · 0.40', 24)}
          </div>
          <div style="flex-grow: 1;"></div>
          <div style="display: flex; gap: 16px; font-size: 12px; color: ${T.sec};"><div>RE-SEARCH</div><div>RETAKE PHOTO</div><div>SAVE AS MANUAL ENTRY</div><div style="color: ${T.red};">DELETE</div></div>
        </div>
      </div>
      ${bottomBar(`VOICE · "one" · "two" · "three" · "none" · "next" · "retake" · "manual"`)}
    </div>
  </div>
</div>
${tail}`;

// ---------- Settings ----------
const field = (k, v, c = T.text) => `<div style="display: flex; justify-content: space-between; align-items: center; gap: 12px; font-size: 13px; padding: 8px 0; border-bottom: 1px solid ${T.line};"><div style="color: ${T.muted};">${k}</div><div style="color: ${c};">${v}</div></div>`;
const toggle = (on) => `<div style="width: 36px; height: 20px; border-radius: 10px; background: ${on ? T.green : T.raised}; position: relative;"><div style="position: absolute; top: 2px; ${on ? 'right: 2px;' : 'left: 2px;'} width: 16px; height: 16px; border-radius: 50%; background: ${T.bg};"></div></div>`;
const radio = (on) => `<div style="width: 14px; height: 14px; border-radius: 50%; border: 2px solid ${on ? T.green : T.muted}; box-sizing: border-box; background: ${on ? T.green : 'transparent'};"></div>`;
const section = (t, body) => `<div style="display: flex; flex-direction: column; gap: 6px;"><div style="${cond} font-weight: 700; font-size: 22px; letter-spacing: 0.08em; color: ${T.text}; padding-bottom: 6px;">${t}</div>${body}</div>`;
const slider = (pct) => `<div style="width: 140px; height: 4px; background: ${T.raised}; position: relative;"><div style="width: ${pct}%; height: 4px; background: ${T.green};"></div><div style="position: absolute; top: -5px; left: ${pct}%; width: 14px; height: 14px; border-radius: 50%; background: ${T.text}; margin-left: -7px;"></div></div>`;
const Settings = `${head}
<div style="width: 1440px; height: 900px; background: ${T.bg}; display: flex; flex-direction: column; box-sizing: border-box;">
  ${topBar({ active: 'SETTINGS', format: '—', listening: false, auto: false })}
  <div style="flex-grow: 1; display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 40px; padding: 28px 40px; min-height: 0; box-sizing: border-box;">
    <div style="display: flex; flex-direction: column; gap: 32px;">
      ${section('IDENTIFICATION', `
        <div style="display: flex; align-items: center; gap: 10px; font-size: 13px; padding: 8px 0;">${radio(true)}<div>GPT-5.6 Luna</div><div style="color: ${T.muted};">· $0.20 / M · default</div></div>
        <div style="display: flex; align-items: center; gap: 10px; font-size: 13px; padding: 8px 0; border-bottom: 1px solid ${T.line};">${radio(false)}<div>Gemini 3.8 Flash</div><div style="color: ${T.muted};">· $0.75 / M</div></div>
        ${field('OpenAI API key', '••••••••••••3f9a · Keychain', T.sec)}
        ${field('Google AI key', 'not set', T.muted)}
        ${field('Local OCR + barcode first', toggle(true))}
        ${field('Skip model when barcode hits', toggle(true))}
        ${field('Auto-accept above', `<div style="display: flex; align-items: center; gap: 10px;">${slider(85)}<div>0.85</div></div>`)}
        ${field('Ask below', `<div style="display: flex; align-items: center; gap: 10px;">${slider(60)}<div>0.60</div></div>`)}
        ${field('Spend this session', '$0.04 · 48 reads', T.sec)}`)}
${section('SHOTS PER FORMAT', `
        <div style="display: grid; grid-template-columns: 90px repeat(4, minmax(0, 1fr)); gap: 6px 10px; font-size: 12px; align-items: center;">
          <div></div><div style="color: ${T.muted};">FRONT</div><div style="color: ${T.muted};">BACK</div><div style="color: ${T.muted};">LABELS</div><div style="color: ${T.muted};">GATEFOLD</div>
          <div>7"</div><div style="color: ${T.muted};">if sleeve</div><div style="color: ${T.muted};">—</div><div style="color: ${T.green};">A + B</div><div style="color: ${T.muted};">—</div>
          <div>12"</div><div style="color: ${T.green};">yes</div><div style="color: ${T.muted};">—</div><div style="color: ${T.green};">A</div><div style="color: ${T.muted};">—</div>
          <div>LP</div><div style="color: ${T.green};">yes</div><div style="color: ${T.green};">yes</div><div style="color: ${T.green};">A</div><div style="color: ${T.green};">if Discogs says</div>
          <div>2×LP</div><div style="color: ${T.green};">yes</div><div style="color: ${T.green};">yes</div><div style="color: ${T.green};">A–D</div><div style="color: ${T.green};">yes</div>
        </div>
        <div style="font-size: 12px; color: ${T.muted}; padding-top: 8px;">Double albums and gatefolds are detected from the Discogs release. Say "add photo" for anything extra.</div>`)}
    </div>
    <div style="display: flex; flex-direction: column; gap: 32px;">
      ${section('DISCOGS', `
        ${field('Account', 'woodyvinyl', T.sec)}
        ${field('Personal token', '••••••••••••kQ2c · Keychain', T.sec)}
        ${field('Add matches to my Collection', toggle(true))}
        ${field('Folder', dd('Uncategorized'), T.sec)}
        ${field('Valuation currency', dd('GBP'), T.sec)}
        ${field('Rate limit', '14 / 60 per minute', T.green)}`)}
      ${section('CAPTURE', `
        ${field('Camera', dd('FaceTime HD · iPhone available'), T.sec)}
        ${field('Auto-capture', toggle(true))}
        ${field('Steady for', `<div style="display: flex; align-items: center; gap: 10px;">${slider(40)}<div>600 ms</div></div>`)}
        ${field('Sharpness threshold', `<div style="display: flex; align-items: center; gap: 10px;">${slider(55)}<div>medium</div></div>`)}
        ${field('Wait for scene change between records', toggle(true))}
        ${field('Photo size', '1600 px · JPEG 85', T.sec)}
        ${field('Photos folder', '~/Library/…/VinylCat/Photos', T.sec)}`)}

      ${section('VOICE', `
        ${field('Listen while scanning', toggle(true))}
        ${field('Recognition', 'On-device (English UK)', T.sec)}
        ${field('Voice', dd('Daniel (Enhanced)'), T.sec)}
        ${field('Speech rate', `<div style="display: flex; align-items: center; gap: 10px;">${slider(55)}<div>1.1×</div></div>`)}
        ${field('Read out matches', toggle(true))}
        ${field('Chimes', toggle(true))}
        ${field('Read candidates when ambiguous', toggle(true))}`)}
      ${section('SESSION', `
        ${field('Default format on launch', dd('Last used'), T.sec)}
        ${field('Skip records already in library', toggle(true))}
        ${field('Value lookups', dd('In background'), T.sec)}
        ${field('Export', 'CSV to ~/Documents/VinylCat/output', T.sec)}`)}
      <div style="flex-grow: 1;"></div>
      <div style="display: flex; gap: 16px; font-size: 12px; color: ${T.sec};"><div>TEST CAMERA</div><div>TEST VOICE</div><div>TEST DISCOGS</div><div>TEST MODEL</div></div>
    </div>
  </div>
</div>
${tail}`;

const files = { Main, ScanReading, ScanMatched, ScanAmbiguous, ScanNeedLabel, ScanAwaitingShot, ScanNotFound, Library, Review, Settings };
for (const [n, html] of Object.entries(files)) writeFileSync(`${n}.dc.html`, html);

const W = 1440, H = 900, GX = 120, GY = 200;
const col = (i) => i * (W + GX), row = (j) => j * (H + GY);
const canvas = {
  pages: [{ id: 'page-1', name: 'Mockups' }, { id: 'page-2', name: 'Directions' }],
  artboards: [
    { file: 'Main.dc.html', title: 'Scan · 1 Armed', x: col(0), y: row(0), w: W, h: H, page: 'page-1' },
    { file: 'ScanReading.dc.html', title: 'Scan · 2 Reading', x: col(1), y: row(0), w: W, h: H, page: 'page-1' },
    { file: 'ScanMatched.dc.html', title: 'Scan · 3 Matched', x: col(2), y: row(0), w: W, h: H, page: 'page-1' },
    { file: 'ScanAmbiguous.dc.html', title: 'Scan · 4 Ambiguous', x: col(0), y: row(1), w: W, h: H, page: 'page-1' },
    { file: 'ScanNeedLabel.dc.html', title: 'Scan · 5 Need label', x: col(1), y: row(1), w: W, h: H, page: 'page-1' },
    { file: 'ScanAwaitingShot.dc.html', title: 'Scan · 6 Awaiting shot (double album)', x: col(2), y: row(1), w: W, h: H, page: 'page-1' },
    { file: 'ScanNotFound.dc.html', title: 'Scan · 7 Not found → Review', x: col(0), y: row(2), w: W, h: H, page: 'page-1' },
    { file: 'Library.dc.html', title: 'Library', x: col(1), y: row(2), w: W, h: H, page: 'page-1' },
    { file: 'Review.dc.html', title: 'Review queue', x: col(2), y: row(2), w: W, h: H, page: 'page-1' },
    { file: 'Settings.dc.html', title: 'Settings', x: col(0), y: row(3), w: W, h: H, page: 'page-1' },
    { file: 'DirectionB.dc.html', title: 'B · Native macOS (not chosen)', x: 0, y: 0, w: W, h: H, page: 'page-2' },
    { file: 'DirectionC.dc.html', title: 'C · Editorial (not chosen)', x: col(1), y: 0, w: W, h: H, page: 'page-2' },
  ],
  annotations: [
    { id: 'flow', x: 0, y: -150, w: 1400, page: 'page-1', text: 'Scan flow, left to right, top to bottom: Armed → Reading → Matched → (Ambiguous | Need label) → Awaiting extra shots → Not found parks to Review. Then Library, Review queue, Settings. Every state is reachable by voice; the bottom bar shows the words that work right now.' },
    { id: 'colours', x: col(1), y: -150, w: 900, page: 'page-1', text: 'State colours: grey armed · amber reading · green matched · orange needs a decision · blue asking for a shot · red parked for review. Same colour drives the chime and the ring.' },
    { id: 'dirs', x: 0, y: -150, w: 700, page: 'page-2', text: 'Unchosen directions kept for reference. A (dark control-room) was picked and became the mockup set on page 1.' },
  ],
  launch: { view: 'canvas', page: 'page-1' },
};
writeFileSync('canvas.json', JSON.stringify(canvas, null, 2));
console.log('wrote', Object.keys(files).length, 'artboards + canvas.json');
