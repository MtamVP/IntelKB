import { SUPABASE_CONFIG } from './config.mjs';

export const DICTIONARY_CATEGORIES = ['chat', 'profanity', 'euphemism', 'english', 'game'];
export function validateEntry(input) {
  const trigger = String(input.trigger || '').normalize('NFC').trim().toLocaleLowerCase('vi').replace(/\s+/g, ' ');
  const expansion = String(input.expansion || '').normalize('NFC').trim().replace(/\s+/g, ' ');
  if (!trigger || trigger.length > 48 || !/^[\p{L}\p{M}\p{N}]+(?: [\p{L}\p{M}\p{N}]+)*$/u.test(trigger)) throw new Error('Từ viết tắt cần 1–48 ký tự chữ/số, có thể có dấu cách.');
  if (!expansion || expansion.length > 240) throw new Error('Nghĩa đầy đủ cần 1–240 ký tự.');
  if (trigger === expansion.toLocaleLowerCase('vi')) throw new Error('Nghĩa đầy đủ cần khác từ viết tắt.');
  if (!DICTIONARY_CATEGORIES.includes(input.category)) throw new Error('Hãy chọn nhóm từ hợp lệ.');
  return {trigger, expansion, category: input.category, auto_replace: Boolean(input.auto_replace)};
}

export class SupabaseClient {
  constructor({storage = localStorage, fetcher = fetch, config = SUPABASE_CONFIG} = {}) {
    this.storage = storage; this.fetcher = fetcher.bind(globalThis); this.config = config;
    this.sessionKey = `intelkb.session.${config.url}`;
    this.session = this.read(this.sessionKey, null);
    this.onChange = () => {}; this.syncing = null;
  }
  read(key, fallback) {
    try { const value = this.storage.getItem(key); return value ? JSON.parse(value) : fallback; } catch { return fallback; }
  }
  async request(path, {method='GET', body, token, headers={}} = {}) {
    const response = await this.fetcher(this.config.url + path, {
      method, headers:{apikey:this.config.publishableKey, 'Content-Type':'application/json', ...(token ? {Authorization:`Bearer ${token}`} : {}), ...headers},
      ...(body !== undefined ? {body:JSON.stringify(body)} : {}), signal:AbortSignal.timeout(15000),
    });
    const raw = await response.text(); let data; try { data = raw ? JSON.parse(raw) : null; } catch { data = null; }
    if (!response.ok) {
      if (['PGRST205','PGRST202'].includes(data?.code)) throw new Error('Chưa thiết lập database cộng đồng. Chủ trang cần chạy SQL mới trong Supabase SQL Editor.');
      if (response.status === 401) throw new Error('Phiên đăng nhập hoặc cấu hình API chưa hợp lệ. Hãy đăng nhập lại.');
      if (response.status === 403) throw new Error('Supabase từ chối quyền truy cập. Kiểm tra SQL và chính sách RLS.');
      throw new Error(data?.msg || data?.message || data?.error_description || `Supabase trả lỗi ${response.status}.`);
    }
    return data;
  }
  setSession(session) {
    const next = {...session, expires_at:session.expires_at || Math.floor(Date.now()/1000) + session.expires_in};
    this.storage.setItem(this.sessionKey, JSON.stringify(next)); this.session = next; this.onChange();
  }
  async signIn(email, password) {
    const data = await this.request('/auth/v1/token?grant_type=password', {method:'POST', body:{email,password}});
    this.setSession(data);
  }
  async signOut() {
    if (this.session?.access_token) await this.request('/auth/v1/logout', {method:'POST', token:this.session.access_token}).catch(() => {});
    this.storage.removeItem(this.sessionKey); this.session = null; this.onChange();
  }
  async accessToken() {
    if (!this.session?.user?.id) throw new Error('Đăng nhập quản trị để tiếp tục.');
    if (this.session.expires_at <= Math.floor(Date.now()/1000) + 60) {
      const data = await this.request('/auth/v1/token?grant_type=refresh_token', {method:'POST', body:{refresh_token:this.session.refresh_token}});
      this.setSession(data);
    }
    return this.session.access_token;
  }
}
