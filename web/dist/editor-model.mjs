import { expandText, replaceSuggestion } from './engine.mjs';

// All offsets use textarea UTF-16 units, including emoji and combining marks.
export function mapPosition(position, changes) {
  let offset = 0;
  for (const c of changes) {
    if (position < c.start) break;
    if (position <= c.end) return c.start + offset + (position === c.start ? 0 : c.replacement.length);
    offset += c.replacement.length - (c.end - c.start);
  }
  return position + offset;
}

function moveRanges(ranges, start, end, insertedLength) {
  const delta = insertedLength - (end - start);
  return ranges.flatMap(r => {
    if (r.end <= start) return [r];
    if (r.start >= end) return [{start:r.start+delta,end:r.end+delta}];
    // Editing a generated word makes that word ordinary editable content again.
    return [];
  });
}

export class EditorModel {
  constructor(index) {
    this.index = index; this.style = 'direct';
    this.current = {text:'',start:0,end:0,ranges:[],report:null};
    this.past = []; this.future = [];
    this.typingAt = 0;
  }
  get text() { return this.current.text; }
  get ranges() { return this.current.ranges; }
  select(start, end = start) {
    if (start !== this.current.start || end !== this.current.end) this.typingAt = 0;
    this.current = {...this.current,start,end};
  }
  commit(next, mergeTyping = false) {
    if (next.text === this.text) { this.current = next; return; }
    if (!mergeTyping) this.past.push(this.current);
    if (this.past.length > 200) this.past.shift();
    this.current = next; this.future = [];
    this.typingAt = 0;
  }
  edit(text, start, end = start, groupTyping = false) {
    if (text === this.text) { this.select(start,end); return; }
    const old = this.text;
    let a = 0, b = old.length, c = text.length;
    while (a < b && a < c && old[a] === text[a]) a++;
    while (b > a && c > a && old[b-1] === text[c-1]) { b--; c--; }
    const now = Date.now();
    const canGroup = groupTyping && start===end && this.current.start===this.current.end && a===this.current.start && b===a;
    const merge = canGroup && this.typingAt && now-this.typingAt<900 && this.past.length>0;
    this.commit({text,start,end,ranges:moveRanges(this.ranges,a,b,c-a),report:this.current.report},merge);
    this.typingAt = canGroup ? now : 0;
  }
  load(text, meanings = {}, autoFill = true) {
    this.commit({text,start:text.length,end:text.length,ranges:[],report:null});
    if(!autoFill)return [];
    const {next,changes} = this.transformed(this.current,true,meanings);
    if (changes.length) this.commit(next);
    return changes;
  }
  transformed(current, completeLast, meanings = {}) {
    const limit = completeLast ? current.text.length : current.start;
    const result = expandText(current.text,limit,this.index,this.style,completeLast,current.ranges,meanings);
    if (!result.changes.length) return {next:current,changes:[]};
    const ranges = current.ranges.map(r=>({start:mapPosition(r.start,result.changes),end:mapPosition(r.end,result.changes)}));
    let delta = 0;
    for (const c of result.changes) {
      ranges.push({start:c.start+delta,end:c.start+delta+c.replacement.length});
      delta += c.replacement.length-(c.end-c.start);
    }
    return {changes:result.changes,next:{text:result.text,start:mapPosition(current.start,result.changes),end:mapPosition(current.end,result.changes),
      ranges,report:{source:current.text,changes:result.changes.map(c=>({from:current.text.slice(c.start,c.end),to:c.replacement}))}}};
  }
  transform(completeLast = false) {
    const {next,changes} = this.transformed(this.current,completeLast);
    if (changes.length) this.commit(next);
    return changes;
  }
  replace(start,end,replacement,{selectResult=false,protect=true}={}) {
    if(!Number.isInteger(start)||!Number.isInteger(end)||start<0||end<start||end>this.text.length)throw new Error('Vùng chọn không hợp lệ.');
    const value=String(replacement),text=this.text.slice(0,start)+value+this.text.slice(end),caret=start+value.length;
    const ranges=moveRanges(this.ranges,start,end,value.length);
    if(protect&&value.length)ranges.push({start,end:caret});
    this.commit({text,start:selectResult?start:caret,end:caret,ranges,report:null});
  }
  choose(item, autoFill = true) {
    const before = this.current;
    const out = replaceSuggestion(before.text,item);
    const added = out.text.length-before.text.length+(item.end-item.start);
    const replacement = out.text.slice(item.start,item.start+added);
    const change = {start:item.start,end:item.end,replacement};
    const keepCaret = before.start > item.end;
    const next = {text:out.text,start:keepCaret?mapPosition(before.start,[change]):out.caret,
      end:keepCaret?mapPosition(before.end,[change]):out.caret,
      ranges:[...moveRanges(before.ranges,item.start,item.end,added),{start:item.start,end:item.start+added}],
      report:{source:before.text,changes:[{from:before.text.slice(item.start,item.end),to:replacement.trimEnd()}]}};
    const transformed = autoFill?this.transformed(next,true):{next,changes:[]};
    transformed.next.report = {source:before.text,changes:[...next.report.changes,...transformed.changes.map(c=>({from:next.text.slice(c.start,c.end),to:c.replacement}))]};
    this.commit(transformed.next);
    return this.current.report.changes;
  }
  undo() {
    if (!this.past.length) return false;
    this.typingAt = 0;
    this.future.push(this.current); this.current = this.past.pop(); return true;
  }
  redo() {
    if (!this.future.length) return false;
    this.typingAt = 0;
    this.past.push(this.current); this.current = this.future.pop(); return true;
  }
  clear() { this.commit({text:'',start:0,end:0,ranges:[],report:null}); }
}
