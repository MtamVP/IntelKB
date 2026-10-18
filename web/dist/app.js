import { makeIndex, suggestionsFor, pendingWords, expandText, telexWord, applyTone } from './engine.mjs';
import { mountDictionary } from './community-ui.mjs';
import { EditorModel } from './editor-model.mjs';
const $ = selector => document.querySelector(selector);
const editor = $('#editor');
const baseWords = await (await fetch(new URL('./words.json', import.meta.url))).json();
let index = makeIndex(baseWords);
const model = new EditorModel(index);
const state = { auto: true, style: 'direct', shift: false, symbols: false, composing: false, completeInput:false, keyTimer: new Map(), suggestions: [] };
const hint = 'Gõ ngắn thôi. Để IntelKB lo phần còn lại.';
let feedbackTimer;
function feedback(text) { $('#feedback').textContent = text; clearTimeout(feedbackTimer); feedbackTimer = setTimeout(() => { $('#feedback').textContent = hint; }, 4500); }
function focusAt(caret) { editor.focus({ preventScroll: true }); editor.setSelectionRange(caret, caret); }
function syncSelection() { model.select(editor.selectionStart,editor.selectionEnd); }
function draw(focus = false) {
  const {text,start,end} = model.current;
  if (editor.value !== text) editor.value = text;
  if (focus) editor.focus({preventScroll:true});
  editor.setSelectionRange(start,end); refresh();
}
function changed(completeLast = false, force = false, deleting = false, groupTyping = false) {
  state.completeInput=completeLast;
  model.edit(editor.value,editor.selectionStart,editor.selectionEnd,groupTyping);
  const changes = !deleting && (force || state.auto) ? model.transform(completeLast) : [];
  draw();
  if (changes.length) feedback('Đã điền '+changes.length+' từ · Hoàn tác để lấy lại chữ gốc.');
}
function refresh() {
  state.suggestions = suggestionsFor(editor.value, editor.selectionStart, index, state.style, model.ranges,state.completeInput);
  const area = $('#suggestions'); area.replaceChildren();
  if (!state.suggestions.length) {
    const span = document.createElement('span'); span.className = 'suggestion-hint'; span.textContent = 'Gõ một từ viết tắt để xem gợi ý'; area.append(span);
  }
  for (const [i, item] of state.suggestions.entries()) {
    const btn = document.createElement('button'); btn.type = 'button'; btn.textContent = item.expansion;
    btn.setAttribute('aria-label', `Thay ${editor.value.slice(item.start, item.end)} bằng ${item.expansion}`);
    const detail = document.createElement('small'); detail.textContent = item.exact ? item.trigger : `Gợi ý từ ${item.trigger}`; btn.append(detail);
    btn.addEventListener('pointerdown', event => event.preventDefault());
    btn.addEventListener('click', () => accept(i)); area.append(btn);
  }
  $('#send').disabled = !editor.value.trim();
  const pending = pendingWords(editor.value,index,state.style,model.ranges);
  $('#pending-words').replaceChildren();
  for (const item of pending) {
    const button=document.createElement('button'); button.textContent=editor.value.slice(item.start,item.end); button.setAttribute('aria-label',`Xem nghĩa ${button.textContent} trong câu`);
    button.addEventListener('pointerdown',event=>event.preventDefault());
    button.onclick=()=>{focusAt(item.end);syncSelection();refresh();}; $('#pending-words').append(button);
  }
  $('#expand-all').disabled=!expandText(editor.value,editor.value.length,index,state.style,true,model.ranges).changes.length;
  $('#undo').disabled=!model.past.length; $('#redo').disabled=!model.future.length;
  $('#copy-result').disabled=!editor.value.trim(); $('#clear-text').disabled=!editor.value;
  $('#text-count').textContent = [...editor.value].length+' ký tự';
  $('#pending-count').textContent = pending.length ? pending.length+' từ chưa điền · chạm gợi ý để chọn' : 'Không còn từ chờ chọn';
  const report=model.current.report;
  $('#conversion-report').hidden=!report;
  $('#conversion-source').textContent=report?.source || '';
  $('#conversion-list').replaceChildren();
  for (const item of report?.changes || []) {
    const chip=document.createElement('span');chip.textContent=item.from+' → '+item.to;$('#conversion-list').append(chip);
  }
}
function accept(i) {
  const item = typeof i === 'object' ? i : state.suggestions[i]; if (!item) return;
  state.completeInput=true;syncSelection(); const changes=model.choose(item); draw(true);
  feedback('Đã chọn nghĩa và điền '+changes.length+' từ trong câu.');
}
function expand(completeLast=false) {
  state.completeInput=completeLast;
  syncSelection(); const changes=model.transform(completeLast);draw(true);
  feedback(changes.length ? 'Đã điền '+changes.length+' từ. Từ nhiều nghĩa vẫn để bạn chọn.' : 'Chọn nghĩa cho các từ còn lại ở hàng gợi ý.');
}
function insert(value, telex = false) {
  const start = editor.selectionStart, end = editor.selectionEnd;
  if (telex && /[a-z]/i.test(value)) {
    const match = editor.value.slice(0, start).match(/[\p{L}]+$/u);
    if (match) {
      const word = telexWord(match[0], value); editor.setRangeText(word, match.index, end, 'end');
    } else editor.setRangeText(value, start, end, 'end');
  } else editor.setRangeText(value, start, end, 'end');
  focusAt(editor.selectionEnd); changed(false,false,false,true);
}
function erase() {
  let a = editor.selectionStart, b = editor.selectionEnd;
  if (a === b && a > 0) {
    const segments=[...new Intl.Segmenter('vi',{granularity:'grapheme'}).segment(editor.value.slice(0,a))];
    a=segments.at(-1)?.index ?? 0;
  }
  editor.setRangeText('', a, b, 'end'); focusAt(a); changed(false,false,true);
}
function undo() {
  if (model.undo()) { state.completeInput=true;draw(true);feedback('Đã hoàn tác · Ctrl+Shift+Z để làm lại.'); }
}
function redo() { if (model.redo()) {state.completeInput=true;draw(true);feedback('Đã làm lại.');} }
function send() {
  if (state.auto) {syncSelection();model.transform(true);draw();}
  const value = editor.value.trim(); if (!value) return;
  const bubble = document.createElement('div'); bubble.className = 'bubble outgoing'; bubble.textContent = value;
  $('#messages').append(bubble); $('#messages').scrollTop = $('#messages').scrollHeight;
  model.clear();draw(true);feedback('Đã gửi vào cuộc trò chuyện mô phỏng.');
}
function flash(key) {
  const button = [...document.querySelectorAll('.key')].find(b => b.dataset.key.toLowerCase() === key.toLowerCase());
  if (!button) return;
  button.classList.add('active'); clearTimeout(state.keyTimer.get(key));
  state.keyTimer.set(key, setTimeout(() => button.classList.remove('active'), 130));
}
function press(key) {
  flash(key);
  if (key === 'Backspace') erase();
  else if (key === 'Shift') { state.shift = !state.shift; renderKeys(); }
  else if (key === 'Symbols') { state.symbols = !state.symbols; renderKeys(); }
  else if (key === 'Enter') send();
  else if (key === ' ') insert(' ');
  else { insert(state.shift ? key.toUpperCase() : key, !state.symbols); if (state.shift) { state.shift = false; renderKeys(); } }
}
function renderKeys() {
  const layouts = state.symbols ? ['1234567890', '-/:;()₫&@"', '.,?!\''] : ['qwertyuiop', 'asdfghjkl', 'zxcvbnm'];
  const host = $('#keys'); host.replaceChildren();
  const add = (row, key, label = key, cls = '') => {
    const button = document.createElement('button'); button.type = 'button'; button.className = `key ${cls}`;
    button.dataset.key = key; button.dataset.label = label; button.textContent = label;
    button.setAttribute('aria-label', { Backspace: 'Xóa ký tự', Shift: 'Chữ hoa', Symbols: 'Đổi chữ và số', Enter: 'Gửi tin nhắn thử', ' ': 'Dấu cách' }[key] || `Phím ${label}`);
    if (key === 'Shift') button.setAttribute('aria-pressed', state.shift);
    button.addEventListener('pointerdown', e => { e.preventDefault(); flash(key); });
    button.addEventListener('click', () => press(key)); row.append(button);
  };
  layouts.forEach((letters, i) => {
    const row = document.createElement('div'); row.className = 'key-row';
    if (i === 2) add(row, 'Shift', state.shift ? '⇧ •' : '⇧', 'wide');
    for (const letter of letters) add(row, letter, state.shift ? letter.toUpperCase() : letter);
    if (i === 2) add(row, 'Backspace', '⌫', 'wide'); host.append(row);
  });
  const last = document.createElement('div'); last.className = 'key-row';
  add(last, 'Symbols', state.symbols ? 'ABC' : '123', 'function'); add(last, ',', ',', 'function');
  add(last, ' ', 'dấu cách', 'space'); add(last, '.', '.', 'function'); add(last, 'Enter', 'gửi ↗', 'return'); host.append(last);
}
editor.addEventListener('beforeinput',event=>{
  if (state.composing || event.isComposing) return;
  if (event.inputType==='historyUndo' || event.inputType==='historyRedo') {
    event.preventDefault();event.inputType==='historyUndo'?undo():redo();
  }
});
editor.addEventListener('input', event => {
  if (!event.isComposing && !state.composing) {
    const complete=['insertFromPaste','insertFromDrop'].includes(event.inputType);
    changed(complete,complete,event.inputType?.startsWith('delete'),event.inputType==='insertText');
  }
});
editor.addEventListener('paste',event=>{
  if (!event.clipboardData) return;
  event.preventDefault();pasteText(event.clipboardData.getData('text/plain'));
});
function pasteText(text) {
  if (!text) {feedback('Clipboard chưa có văn bản.');return;}
  editor.setRangeText(text,editor.selectionStart,editor.selectionEnd,'end');
  changed(true,true);editor.focus({preventScroll:true});
}
editor.addEventListener('compositionstart', () => { syncSelection();state.composing = true; });
editor.addEventListener('compositionend', () => { state.composing = false; changed(); });
for (const name of ['click','select','keyup']) editor.addEventListener(name,()=>{
  if(!state.composing){
    if (editor.selectionStart!==model.current.start || editor.selectionEnd!==model.current.end) state.completeInput=false;
    syncSelection();refresh();
  }
});
editor.addEventListener('keydown', event => {
  if (event.isComposing || state.composing || event.keyCode===229) return;
  flash(event.key);
  if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); send(); }
  if (event.ctrlKey || event.metaKey) {
    const key=event.key.toLowerCase();
    if (key==='z') {event.preventDefault();event.shiftKey?redo():undo();}
    if (key==='y') {event.preventDefault();redo();}
    if (event.code==='Space') {event.preventDefault();accept(0);}
  }
});
$('#send').addEventListener('click', send); $('#undo').addEventListener('click', undo);
$('#redo').addEventListener('click',redo);
$('#clear-text').addEventListener('click',()=>{syncSelection();model.clear();draw(true);feedback('Đã xóa ô nhập. Có thể hoàn tác.');});
$('#paste-text').addEventListener('pointerdown',e=>e.preventDefault());
$('#paste-text').addEventListener('click',async()=>{
  try {pasteText(await navigator.clipboard.readText());}
  catch {editor.focus({preventScroll:true});feedback('Trình duyệt chưa cho đọc clipboard. Bấm Ctrl+V hoặc giữ ô nhập để dán.');}
});
$('#copy-result').addEventListener('click',async()=>{
  if (state.auto) {syncSelection();model.transform(true);draw();}
  try {await navigator.clipboard.writeText(editor.value);feedback('Đã sao chép nội dung trong ô nhập.');}
  catch {editor.focus({preventScroll:true});editor.select();feedback('Đã chọn văn bản. Bấm Ctrl+C để sao chép.');}
});
$('#expand-all').addEventListener('pointerdown',e=>e.preventDefault());
$('#expand-all').addEventListener('click',()=>expand(true));
$('#auto').addEventListener('click', () => {
  state.auto = !state.auto; $('#auto').setAttribute('aria-checked', state.auto); $('#mode-label').textContent = state.auto ? 'Tự động điền đang bật' : 'Chọn nghĩa thủ công';
  if (state.auto) expand(true);
  feedback(state.auto ? 'Đã bật tự động điền. Gõ hnay rồi nhấn cách để thử.' : 'Chế độ gợi ý: chạm một nghĩa để chọn.');
});
function setStyle(style) {
  model.style=style;
  state.style = style; $('#direct').setAttribute('aria-pressed', style === 'direct'); $('#gentle').setAttribute('aria-pressed', style === 'gentle');
  $('#style-help').textContent = style === 'direct' ? 'Hiện nguyên nghĩa, kể cả từ tục.' : 'Ưu tiên cách nói nhẹ, ẩn gợi ý tục.';
  $('#vcl-demo').textContent = style === 'direct' ? 'vãi cả lồn' : 'vãi cả lúa'; refresh();
}
$('#direct').addEventListener('click', () => setStyle('direct')); $('#gentle').addEventListener('click', () => setStyle('gentle'));
document.querySelectorAll('[data-sample]').forEach(button => button.addEventListener('click', () => {
  state.completeInput=true;syncSelection();
  const changes=model.load(button.dataset.sample,JSON.parse(button.dataset.meanings || '{}'));draw(true);
  const remaining=pendingWords(model.text,index,state.style,model.ranges).length;
  feedback(changes.length ? 'Câu mẫu đã điền '+changes.length+' từ.'+(remaining ? ' Chọn nghĩa cho từ còn lại.' : ' Bạn có thể gõ tiếp hoặc sao chép.') : 'Đã điền câu mẫu. Chạm từ viết tắt bên dưới để chọn nghĩa nếu có.');
  if (window.innerWidth < 760) $('.demo').scrollIntoView({ behavior: 'smooth', block: 'center' });
}));
document.querySelectorAll('[data-tone]').forEach(button => {
  button.addEventListener('pointerdown', e => e.preventDefault());
  button.addEventListener('click', () => {
    const match = editor.value.slice(0, editor.selectionStart).match(/[\p{L}]+$/u); if (!match) return;
    const word = applyTone(match[0], button.dataset.tone); editor.setRangeText(word, match.index, editor.selectionStart, 'end'); focusAt(editor.selectionEnd); changed();
  });
});
$('#reset').addEventListener('click', () => {
  model.clear();draw();
  $('#messages').querySelectorAll('.outgoing').forEach(el => el.remove()); refresh(); feedback('Bắt đầu lại. Thử một câu mới nhé.');
});
mountDictionary(baseWords, entries=>{
  index=makeIndex(entries);model.index=index;
  const demo=entries.filter(row=>row.demo).length,approved=entries.length-demo;
  $('#keyboard-source').textContent=`${demo} nghĩa mẫu thử · ${approved} nghĩa đã duyệt`;
  refresh();
});
renderKeys(); refresh();
