import {CommunityStore} from './community-store.mjs';

const CATS = ['chat','profanity','euphemism','english','game'];

export class AdminDataStore extends CommunityStore {
  // ── Dictionary CRUD ─────────────────────────────────────────────────────

  async list({status='',source='',category='',trashed='hide',search='',offset=0,limit=51}={}) {
    const token = await this.accessToken();
    let q = `/rest/v1/intelkb_dictionary?select=*&order=created_at.desc,id&limit=${limit}&offset=${offset}`;
    if (status)             q += `&status=eq.${encodeURIComponent(status)}`;
    if (source)             q += `&source=eq.${encodeURIComponent(source)}`;
    if (category)           q += `&category=eq.${encodeURIComponent(category)}`;
    if (trashed === 'hide') q += `&trashed_at=is.null`;
    else if (trashed === 'only') q += `&trashed_at=not.is.null`;
    const rows = await this.request(q, {token});
    if (!search) return rows;
    const s = this._norm(search);
    return rows.filter(r => this._norm(r.trigger).includes(s) || this._norm(r.expansion).includes(s));
  }

  async upsert(data, reason='') {
    const token = await this.accessToken();
    return this.request('/rest/v1/rpc/intelkb_admin_upsert', {method:'POST', token, body:{
      p_id:            data.id || null,
      p_trigger:       data.trigger,
      p_expansion:     data.expansion,
      p_category:      data.category,
      p_auto_replace:  Boolean(data.auto_replace),
      p_status:        data.status || 'draft',
      p_source:        data.source || 'import',
      p_example:       data.example || '',
      p_source_ref:    data.source_ref || '',
      p_internal_note: data.internal_note || '',
      p_reason:        reason,
    }});
  }

  async trash(id, reason='') {
    const token = await this.accessToken();
    return this.request('/rest/v1/rpc/intelkb_admin_trash', {method:'POST', token,
      body:{p_id:id, p_reason:reason}});
  }

  async restore(id) {
    const token = await this.accessToken();
    return this.request('/rest/v1/rpc/intelkb_admin_restore', {method:'POST', token, body:{p_id:id}});
  }

  async history(id) {
    const token = await this.accessToken();
    return this.request('/rest/v1/rpc/intelkb_entry_history', {method:'POST', token, body:{p_id:id}});
  }

  async stats() {
    const token = await this.accessToken();
    return this.request('/rest/v1/rpc/intelkb_admin_stats', {method:'POST', token, body:{}});
  }

  // ── Bulk import ─────────────────────────────────────────────────────────

  async bulkImport(rows, sourceName='') {
    const token = await this.accessToken();
    return this.request('/rest/v1/rpc/intelkb_bulk_import', {method:'POST', token,
      body:{p_rows:rows, p_source_name:sourceName}});
  }

  // ── Bulk review (P1) ────────────────────────────────────────────────────

  async bulkReview(items) {
    const token = await this.accessToken();
    return this.request('/rest/v1/rpc/intelkb_bulk_review', {method:'POST', token,
      body:{p_items:items}});
  }

  // ── Import parsing ───────────────────────────────────────────────────────

  parseInput(text, hint='auto') {
    const t = text.trim();
    if (!t) return {rows:[], errors:[{index:0, reason:'Nội dung trống', raw:''}]};
    if (hint==='jsonl' || (hint==='auto' && t.startsWith('{') && t.includes('\n')))
      return this._parseJSONL(t);
    if (hint==='json' || (hint==='auto' && (t.startsWith('[') || (t.startsWith('{') && !t.includes('\n')))))
      return this._parseJSON(t);
    return this._parseCSV(t);
  }

  _parseCSV(text) {
    const lines = text.split(/\r?\n/);
    const errors = [];
    // Parse header row
    const headers = this._csvRow(lines[0]).map(h => h.toLowerCase().trim());
    const rows = [];
    for (let i = 1; i < lines.length; i++) {
      if (!lines[i].trim()) continue;
      const cells = this._csvRow(lines[i]);
      const obj = {};
      headers.forEach((h, j) => { obj[h] = cells[j] ?? ''; });
      rows.push(obj);
    }
    return {rows: this._normalize(rows, errors), errors};
  }

  _csvRow(line) {
    const cells = []; let cur = '', inQ = false;
    for (let i = 0; i < line.length; i++) {
      const ch = line[i];
      if (ch === '"') {
        if (inQ && line[i+1] === '"') { cur += '"'; i++; }
        else inQ = !inQ;
      } else if (ch === ',' && !inQ) { cells.push(cur); cur = ''; }
      else cur += ch;
    }
    cells.push(cur);
    return cells.map(c => c.trim());
  }

  _parseJSON(text) {
    const errors = [];
    try {
      const data = JSON.parse(text);
      const arr = Array.isArray(data) ? data : (data.rows || data.data || Object.values(data));
      return {rows: this._normalize(arr, errors), errors};
    } catch(e) {
      return {rows:[], errors:[{index:0, reason:'JSON không hợp lệ: '+e.message, raw:text.slice(0,80)}]};
    }
  }

  _parseJSONL(text) {
    const rows = [], errors = [];
    text.split(/\r?\n/).forEach((line, i) => {
      if (!line.trim()) return;
      try { rows.push(JSON.parse(line)); }
      catch { errors.push({index:i+1, reason:'JSON không hợp lệ', raw:line.slice(0,80)}); }
    });
    return {rows: this._normalize(rows, errors), errors};
  }

  _normalize(rows, errors) {
    return rows.filter(r => {
      if (!r || typeof r !== 'object') return false;
      return (r.trigger||r.abbreviation||r['từ viết tắt']) &&
             (r.expansion||r.meaning||r['nghĩa']||r['nghĩa đầy đủ']);
    }).map(r => ({
      trigger:      String(r.trigger||r.abbreviation||r['từ viết tắt']||'').trim(),
      expansion:    String(r.expansion||r.meaning||r['nghĩa']||r['nghĩa đầy đủ']||'').trim(),
      category:     CATS.includes(r.category||r['nhóm']) ? (r.category||r['nhóm']) : 'chat',
      auto_replace: Boolean(r.auto_replace||r['tự bung']),
      example:      String(r.example||r['ví dụ']||'').trim().slice(0,500),
    }));
  }

  // ── Export ───────────────────────────────────────────────────────────────

  toCSV(rows) {
    const headers = ['trigger','expansion','category','auto_replace','status','example','source_ref','source','revision'];
    const safe = v => {
      const s = String(v??'').replace(/^[=+\-@\t\r]/, "'$&");
      return s.includes(',')||s.includes('"')||s.includes('\n')
        ? `"${s.replace(/"/g,'""')}"` : s;
    };
    return [headers.join(','), ...rows.map(r => headers.map(h => safe(r[h])).join(','))].join('\n');
  }

  toJSONL(rows) {
    return rows.map(r => JSON.stringify(r)).join('\n');
  }

  sampleCSV() {
    return [
      'trigger,expansion,category,auto_replace,example',
      'hem,không,chat,true,"Hem đi được không?"',
      'vcl,vãi cả lồn,profanity,false,',
      'xl,xin lỗi,chat,true,"xl bạn nha"',
    ].join('\n');
  }

  // ── Internal helpers ─────────────────────────────────────────────────────

  _norm(s) {
    return String(s||'').normalize('NFD').replace(/\p{M}/gu,'').toLowerCase();
  }
}
