export const normalize = s => s.normalize('NFC').trim().replace(/\s+/gu,' ').toLocaleLowerCase('vi');
const ordinaryAuto = new Set('ko k k0 kh hk hông hong hok kô khum đc dc bik bít bjt j ji z zậy r rùi òi oy òy cx cũg đag vs bth hnay hqua baoh bgio ntn ntnao nthe tnào tsao chs kbt ksao nch mng mngười ngta nta ny ngyeu nyc ae mik mjh dth dthw tks thx sr sorry sry in4 info sđt sdt stk klq cmsn hpbd bsvv đr dr cty đcmm dcmm đcm dcm cmm clmm đhs dhs tđn tdn đbh dbh'.split(' '));
const styleTriggers = new Set(['vcl', 'sml']);

// Common chat spellings in the bundled demo. Published rows still obey the
// moderator's auto_replace flag, and multi-meaning entries still need a choice.
for (const trigger of ['ms','nhg','nhưg','nhìu','nhiu','thui','thoy','hoy','wa','wá','qá',
  'thíck','dthuong','dthương','đz','đzai','dz','dzai','hphuc','hphúc','qtam','qtâm',
  'qtrong','qtr','cgắng','ktra','btap','btvn','hkì','trhoc','vdu','vde','vđề',
  'nchung','lquan','khieu','k hiểu','nữaa','cừi','bùn','đii','dii','đou','dou',
  'đei','dei','zô','zo','zề','ze','tvi','helo']) ordinaryAuto.add(trigger);

// Expose the demo defaults for catalogue labels; published rows use their saved flag.
export const defaultAutoFill = trigger => ordinaryAuto.has(normalize(trigger)) || styleTriggers.has(normalize(trigger));

export function makeIndex(rows) {
  const index = new Map();
  for (const row of rows) {
    const trigger = normalize(row.trigger);
    if (!index.has(trigger)) index.set(trigger, []);
    const existing = index.get(trigger).findIndex(x => normalize(x.expansion) === normalize(row.expansion));
    if (existing < 0) index.get(trigger).push(row);
    else if (row.custom) index.get(trigger)[existing] = row;
  }
  return index;
}

export function optionsFor(trigger, index, style = 'direct') {
  const all = index.get(normalize(trigger)) || [];
  return [...all].filter(row => style !== 'gentle' || row.category !== 'profanity').sort((a, b) => {
    const rank = row => style === 'direct' ? (row.category === 'profanity' ? 0 : row.category === 'euphemism' ? 2 : 1) : (row.category === 'euphemism' ? 0 : 1);
    return rank(a) - rank(b);
  });
}

export function activeToken(text, caret, index) {
  if (protectedTextRanges(text).some(r => r.start < caret && r.end >= caret)) return null;
  const containing = [...text.matchAll(/[\p{L}\p{M}\p{N}]+/gu)].find(m => m.index < caret && m.index + m[0].length >= caret);
  if (containing && containing.index + containing[0].length > caret) {
    return {start: containing.index, end: containing.index + containing[0].length, trigger: normalize(containing[0])};
  }
  const before = text.slice(0, caret);
  // Preserve native JS UTF-16 offsets for textarea selections.
  const last = before.match(/[\p{L}\p{M}\p{N}]+\s*$/u);
  if (!last) return null;
  const trimmed = last[0].trimEnd();
  let result = { start: last.index, end: last.index + trimmed.length, trigger: normalize(trimmed) };
  // A phrase may cross whitespace but never punctuation or newlines.
  const tail = before.slice(0, result.end).match(/(?:[\p{L}\p{M}\p{N}]+[ \t]+){0,3}[\p{L}\p{M}\p{N}]+$/u);
  if (tail) {
    for (const trigger of index.keys()) {
      if (!trigger.includes(' ')) continue;
      const escaped = trigger.split(' ').map(part => part.replace(/[.*+?^$()|[\]{}\\]/g, '\\$&')).join('[ \\t]+');
      const pattern = new RegExp('(?:^|[^\\p{L}\\p{N}_])(' + escaped + ')$', 'iu');
      const match = before.slice(0, result.end).match(pattern);
      if (match && match[1].length > result.end - result.start) result = { start: result.end - match[1].length, end: result.end, trigger };
    }
  }
  return protectedTextRanges(text).some(r => result.start < r.end && result.end > r.start) ? null : result;
}

// These regions are literal content, never abbreviations.
export function protectedTextRanges(text) {
  const tick = String.fromCharCode(96);
  const patterns = [new RegExp(tick.repeat(3) + '[\\s\\S]*?(?:' + tick.repeat(3) + '|$)', 'g'),
    new RegExp(tick + '[^' + tick + '\\n]*(?:' + tick + '|$)', 'g'),
    /(?:https?:\/\/|www\.)[^\s<>]+/giu,
    /[\p{L}\p{N}._%+-]+@[\p{L}\p{N}.-]+\.[\p{L}]{2,}/gu,
    /(?<![\p{L}\p{M}\p{N}_])[@#][\p{L}\p{M}\p{N}_]+/gu,
    /[\p{L}\p{M}\p{N}]+(?:_[\p{L}\p{M}\p{N}]+)+/gu];
  // Preserve milliseconds in measurements such as 20 ms or 1.5 ms.
  patterns.push(/\b\d+(?:[.,]\d+)?[ \t]*ms\b/giu);
  return patterns.flatMap(pattern => [...text.matchAll(pattern)].map(m => ({start:m.index,end:m.index+m[0].length})));
}

export function pendingWords(text, index, style, excluded = []) {
  const protectedRanges = [...protectedTextRanges(text), ...excluded];
  const tokens = [...text.matchAll(/[\p{L}\p{M}\p{N}]+/gu)];
  const max = Math.max(1, ...[...index.keys()].map(k => k.split(' ').length));
  const result = [];
  for (let i = 0; i < tokens.length; i++) {
    for (let n = Math.min(max, tokens.length - i); n >= 1; n--) {
      const slice = tokens.slice(i, i + n);
      if (slice.some((t, j) => j && !/^[ \t]+$/.test(text.slice(slice[j - 1].index + slice[j - 1][0].length, t.index)))) continue;
      const trigger = normalize(slice.map(t => t[0]).join(' '));
      const start = slice[0].index, end = slice.at(-1).index + slice.at(-1)[0].length;
      if (protectedRanges.some(r => start < r.end && end > r.start)) continue;
      const options = optionsFor(trigger, index, style);
      if (options.length) {
        result.push({trigger, start: slice[0].index, end: slice.at(-1).index + slice.at(-1)[0].length, options});
        i += n - 1; break;
      }
    }
  }
  return result;
}

export function suggestionsFor(text, caret, index, style, excluded = [], completeInput = false) {
  if (protectedTextRanges(text).some(r => r.start < caret && r.end >= caret)) return [];
  let token = activeToken(text, caret, index);
  if (token && excluded.some(r => token.start < r.end && token.end > r.start)) token = null;
  const exact = token ? optionsFor(token.trigger, index, style) : [];
  if (exact.length) return exact.map(row => ({ ...row, ...token, exact: true }));
  const result = [];
  if (!completeInput && token?.trigger.length >= 2) {
    for (const trigger of index.keys()) {
      if (trigger.startsWith(token.trigger)) result.push(...optionsFor(trigger, index, style).map(row => ({ ...row, start: token.start, end: token.end, exact: false })));
      if (result.length >= 8) break;
    }
  }
  if (!result.length) {
    const pending = pendingWords(text,index,style,excluded);
    token = pending.filter(t=>t.end<=caret).at(-1) || pending.find(t=>t.start>=caret);
    if (token) return token.options.map(row=>({...row,...token,exact:true}));
  }
  return result.slice(0, 8);
}

export function autoCandidate(text, caret, index, style) {
  if (!/[\s.,!?;:]/u.test(text[caret - 1] || '')) return null;
  const token = activeToken(text, caret, index);
  if (!token) return null;
  const options = optionsFor(token.trigger, index, style);
  const all = index.get(token.trigger) || [];
  if (!options.length) return null;
  const managed = options[0].custom || options[0].status === 'approved';
  if (styleTriggers.has(token.trigger) && (!managed || options[0].auto_replace)) return { ...options[0], ...token };
  // Ambiguous entries remain manual even if a style hides one of the meanings.
  if (!(managed ? options[0].auto_replace : ordinaryAuto.has(token.trigger)) || all.length !== 1) return null;
  return { ...options[0], ...token };
}

export function expandText(text, caret, index, style, completeLast = false, excluded = [], meanings = {}) {
  const changes = [];
  for (const token of pendingWords(text, index, style, excluded)) {
    if (token.end > caret || (!completeLast && token.end === caret)) continue;
    const all = index.get(token.trigger) || [];
    // A labelled sample can explicitly choose a meaning; pasted text never supplies this map.
    const chosen = token.options.find(row => row.expansion === meanings[token.trigger]);
    const first = chosen || token.options[0];
    const managed = first.custom || first.status === 'approved';
    if (!chosen && !(styleTriggers.has(token.trigger) && (!managed || first.auto_replace)) && (all.length !== 1 || !(managed ? first.auto_replace : ordinaryAuto.has(token.trigger)))) continue;
    const item = {...first, ...token};
    const replacement = caseExpansion(text.slice(item.start,item.end),item.expansion);
    changes.push({...item, replacement});
  }
  let result = text;
  for (const item of [...changes].reverse()) result = result.slice(0, item.start) + item.replacement + result.slice(item.end);
  const offset = changes.reduce((n, c) => n + c.replacement.length - (c.end - c.start), 0);
  return {text:result, caret:caret + offset, changes};
}

export function replaceSuggestion(text, item) {
  const typed = text.slice(item.start, item.end);
  const replacement = caseExpansion(typed,item.expansion);
  const suffix = text.slice(item.end);
  const space = suffix.length === 0 ? ' ' : '';
  return { text: text.slice(0, item.start) + replacement + space + suffix, caret: item.start + replacement.length + space.length };
}

function caseExpansion(typed,expansion) {
  let replacement = expansion;
  if (typed === typed.toLocaleUpperCase('vi') && typed.length > 1) replacement = replacement.toLocaleUpperCase('vi');
  else if (/^\p{Lu}/u.test(typed)) replacement = replacement[0].toLocaleUpperCase('vi') + replacement.slice(1);
  return replacement;
}

const vowelRows = ['aàáảãạ', 'ăằắẳẵặ', 'âầấẩẫậ', 'eèéẻẽẹ', 'êềếểễệ', 'iìíỉĩị', 'oòóỏõọ', 'ôồốổỗộ', 'ơờớởỡợ', 'uùúủũụ', 'ưừứửữự', 'yỳýỷỹỵ'];
const toneNumber = { f: 1, s: 2, r: 3, x: 4, j: 5, z: 0 };
const base = ch => { const row = vowelRows.find(r => r.includes(ch.toLowerCase())); return row ? row[0] : ch.toLowerCase(); };

export function applyTone(word, tone) {
  if (!(tone in toneNumber)) return word;
  const chars = [...word.normalize('NFC')];
  let positions = chars.map((ch, i) => vowelRows.some(r => r.includes(ch.toLowerCase())) ? i : -1).filter(i => i >= 0);
  if (positions.length > 1 && positions[0] === 1 && ((base(chars[0]) === 'q' && base(chars[1]) === 'u') || (base(chars[0]) === 'g' && base(chars[1]) === 'i'))) positions.shift();
  if (!positions.length) return word;
  let target = positions.findLast(i => ['ê', 'ơ'].includes(base(chars[i])));
  if (target === undefined) {
    const cluster = positions.map(i => base(chars[i])).join('');
    if (positions.length >= 3) target = positions[1];
    else if (positions.length === 2 && (positions.at(-1) < chars.length - 1 || ['oa', 'oe', 'uy'].includes(cluster))) target = positions[1];
    else target = positions[0];
  }
  for (const i of positions) {
    const row = vowelRows.find(r => r.includes(chars[i].toLowerCase()));
    const value = row[i === target ? toneNumber[tone] : 0];
    chars[i] = chars[i] === chars[i].toUpperCase() ? value.toUpperCase() : value;
  }
  return chars.join('');
}

export function telexWord(word, key) {
  const k = key.toLowerCase();
  if (k in toneNumber && /[aeiouyăâêôơư]/iu.test(word)) return applyTone(word, k);
  const combos = { aa: 'â', aw: 'ă', ee: 'ê', oo: 'ô', ow: 'ơ', uw: 'ư', dd: 'đ' };
  if (k === 'w' && /uo$/iu.test(word)) return word.slice(0, -2) + 'ươ';
  const last = word.at(-1) || '';
  const replacement = combos[base(last) + k];
  if (replacement) {
    const row = vowelRows.find(r => r.includes(last.toLowerCase()));
    const tone = row ? row.indexOf(last.toLowerCase()) : 0;
    const newRow = vowelRows.find(r => r[0] === replacement);
    let changed = newRow ? newRow[tone] : replacement;
    if (last === last.toUpperCase()) changed = changed.toUpperCase();
    return word.slice(0, -1) + changed;
  }
  // Common Vietnamese uow sequence: uo + w → ươ.
  return word + key;
}
