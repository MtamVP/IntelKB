import { SUPABASE_CONFIG } from './config.mjs';
import { SupabaseClient, validateEntry } from './dictionary-store.mjs';

// Reuse the Auth/HTTP transport only; proposals never enter the keyboard index.
export class CommunityStore extends SupabaseClient {
  constructor(options={}) {
    super(options); this.draftKey='intelkb.community.drafts.v1';
    this.cacheKey=`intelkb.community.approved.${this.config.url}`;
  }
  get drafts() {return this.read(this.draftKey,[]);}
  saveDrafts(rows) {this.storage.setItem(this.draftKey,JSON.stringify(rows));}
  discardDraft(receipt) {this.saveDrafts(this.drafts.filter(row=>row.receipt!==receipt));}
  async loadCatalogue() {
    const rows=[];
    for(let offset=0;;offset+=1000) {
      // Deliberately anonymous, even if this browser has an admin session.
      const page=await this.request(`/rest/v1/intelkb_dictionary?status=eq.approved&select=id,trigger,expansion,category,auto_replace,revision,status,source&order=id&limit=1000&offset=${offset}`);
      rows.push(...page);if(page.length<1000)break;
    }
    this.storage.setItem(this.cacheKey,JSON.stringify(rows));return rows;
  }
  cachedCatalogue() {return this.read(this.cacheKey,null);}
  async checkPair(trigger,expansion,excludeId=null) {
    return this.request('/rest/v1/rpc/intelkb_check_pair',{method:'POST',body:{p_trigger:trigger,p_expansion:expansion,p_exclude_id:excludeId}});
  }
  async reviewQueue({kind='proposals',status='pending',search='',category='',offset=0,limit=50,grouped=true}={}) {
    const token=await this.accessToken();
    return this.request('/rest/v1/rpc/intelkb_review_queue',{method:'POST',token,body:{p_kind:kind,p_status:status,p_search:search,p_category:category,p_offset:offset,p_limit:limit,p_grouped:grouped}});
  }
  async reviewBatch(items,decision,note='',options={}) {
    const token=await this.accessToken();
    return this.request('/rest/v1/rpc/intelkb_review_batch',{method:'POST',token,body:{p_items:items,p_decision:decision,p_note:note,p_options:options}});
  }
  async submit(input,context={}) {
    const word=validateEntry(input), action=context.action || 'new';
    if(!['new','add_meaning','edit'].includes(action))throw new Error('Loại đóng góp không hợp lệ.');
    const target=context.target;
    if(action!=='new' && (!target?.id || !Number.isInteger(target.revision)))throw new Error('Hãy chọn một mục đã công bố trước khi đề xuất sửa.');
    const explanation=String(context.explanation||'').trim(),name=String(context.name||'').trim();
    if(explanation.length>1000 || name.length>60)throw new Error('Ghi chú tối đa 1000 ký tự, tên tối đa 60 ký tự.');
    const draft={...word,action,target:action==='new'?null:{id:target.id,revision:target.revision},explanation,name,receipt:context.receipt||crypto.randomUUID()};
    const drafts=this.drafts.filter(row=>row.receipt!==draft.receipt);drafts.push(draft);this.saveDrafts(drafts);
    const payload={p_receipt:draft.receipt,p_action:action,p_trigger:word.trigger,p_expansion:word.expansion,p_category:word.category,
      p_auto_replace:word.auto_replace,p_target_id:draft.target?.id||null,p_base_revision:draft.target?.revision||null,p_explanation:explanation,p_contributor_name:name};
    const response=await this.request('/rest/v1/rpc/intelkb_submit_proposal',{method:'POST',body:payload});
    this.discardDraft(draft.receipt);return response;
  }
  async isAdmin() {
    const token=await this.accessToken();
    return (await this.request('/rest/v1/rpc/intelkb_is_admin',{method:'POST',token,body:{}}))===true;
  }
  async adminRows(kind,status,offset=0) {
    const token=await this.accessToken();
    const table=kind==='seeds'?'intelkb_dictionary':'intelkb_proposals';
    const filter=kind==='seeds'?'&source=eq.bootstrap':'';
    return this.request(`/rest/v1/${table}?select=*&status=eq.${encodeURIComponent(status)}${filter}&order=created_at,id&limit=51&offset=${offset}`,{token});
  }
  async target(id) {
    const token=await this.accessToken();
    const rows=await this.request(`/rest/v1/intelkb_dictionary?id=eq.${encodeURIComponent(id)}&select=*`,{token});return rows[0]||null;
  }
  async review(row,kind,decision,note,override) {
    const token=await this.accessToken();
    if(kind==='seeds')return this.request('/rest/v1/rpc/intelkb_review_seed',{method:'POST',token,body:{p_id:row.id,p_decision:decision,p_revision:row.revision,p_override:override}});
    return this.request('/rest/v1/rpc/intelkb_review_proposal',{method:'POST',token,body:{p_id:row.id,p_decision:decision,p_note:note,p_override:override}});
  }
}
