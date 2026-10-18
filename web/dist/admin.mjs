import {CommunityStore} from './community-store.mjs';
import {validateEntry} from './dictionary-store.mjs';
import {groupReviewRows} from './contribution-tools.mjs';
import {normalize} from './engine.mjs';
const el=id=>document.getElementById(id),store=new CommunityStore();
const categoryNames={chat:'Nhắn tin',profanity:'Từ tục',euphemism:'Nói nhẹ',english:'Tiếng Anh',game:'Game'};
let allowed=false,rows=[],page=0,total=0,current=null,advanced=true,busy=false,loadVersion=0,searchTimer,decision='accept',batch=[],results=[];
const selected=new Map(),edits=new Map();
const filtersKey='intelkb.review.filters.v2';
function status(message,error=false){el('admin-status').textContent=message;el('admin-status').classList.toggle('error',error);}
function node(tag,text,cls=''){const element=document.createElement(tag);if(text!==undefined)element.textContent=text;if(cls)element.className=cls;return element;}
function canReview(row){return ['draft','pending'].includes(row.status);}
function closeDetail(){current=null;el('review-form').hidden=true;el('review-empty').hidden=false;}
function hide(){allowed=false;loadVersion++;selected.clear();edits.clear();rows=[];closeDetail();el('queue-list').replaceChildren();el('admin-panel').hidden=true;el('admin-login').hidden=false;el('admin-logout').hidden=true;el('review-results').hidden=true;el('batch-dialog').close();}
function selection(){
  for(const id of ['queue-kind','queue-filter','queue-search','queue-category','queue-grouped','queue-compact','queue-reload'])el(id).disabled=busy;
  const n=selected.size;el('selected-count').textContent=n?`${n} mục đã chọn · trang hiện tại`:'Chưa chọn mục';
  for(const id of ['bulk-accept','bulk-reject','clear-selection'])el(id).disabled=!n||busy;
  el('select-page').disabled=busy||!rows.some(canReview);
  for(const box of el('queue-list').querySelectorAll('input[data-id]')){box.checked=selected.has(box.dataset.id);box.disabled=busy||!canReview(rows.find(row=>row.id===box.dataset.id));}
  for(const checkbox of el('queue-list').querySelectorAll('input[data-group]')){
    const group=rows.filter(row=>normalize(row.trigger)===checkbox.dataset.group&&canReview(row));
    checkbox.disabled=busy||!group.length;
    const count=group.filter(row=>selected.has(row.id)).length;checkbox.checked=Boolean(group.length)&&count===group.length;checkbox.indeterminate=count>0&&count<group.length;
  }
  el('queue-prev').disabled=busy||page===0;el('queue-next').disabled=busy||(page+1)*50>=total;
}
function saveEdit(){if(!current)return;edits.set(current.id,{expansion:el('review-expansion').value,category:el('review-category').value,auto_replace:el('review-auto').checked,note:el('review-note').value});}
function render(){
  const host=el('queue-list');host.replaceChildren();
  const groups=el('queue-grouped').checked?groupReviewRows(rows):[['',rows]];
  for(const [trigger,items] of groups){
    if(trigger && items.length>1){
      const tr=node('tr',undefined,'review-group'),cell=node('td');cell.colSpan=6;
      const label=node('label'),box=node('input');box.type='checkbox';box.dataset.group=trigger;box.disabled=busy||!items.some(canReview);box.setAttribute('aria-label',`Chọn cụm ${trigger} trên trang này`);
      box.onchange=()=>{for(const row of items.filter(canReview))box.checked?selected.set(row.id,row):selected.delete(row.id);selection();};
      label.append(box,node('strong',trigger),node('span',`${items.length} mục trong trang · chọn cả cụm`));cell.append(label);tr.append(cell);host.append(tr);
    }
    for(const row of items){
      const tr=node('tr');if(current?.id===row.id)tr.classList.add('current');
      const selectCell=node('td'),check=node('input');check.type='checkbox';check.dataset.id=row.id;check.disabled=busy||!canReview(row);check.setAttribute('aria-label',`Chọn ${row.trigger}: ${row.expansion}`);check.onchange=()=>{check.checked?selected.set(row.id,row):selected.delete(row.id);selection();};selectCell.append(check);
      const meaning=node('td');meaning.append(node('span',row.expansion));
      if(row.explanation)meaning.append(node('small',row.explanation));
      const meta=[row.action==='edit'?'Sửa nghĩa':row.action==='add_meaning'?'Thêm nghĩa':row.source==='bootstrap'?'Khởi tạo':'Từ mới'];
      if(row.created_at)meta.push(new Date(row.created_at).toLocaleDateString('vi-VN'));
      meaning.append(node('small',meta.join(' · ')));
      const actions=node('td'),open=node('button','Xem / sửa');open.type='button';open.onclick=()=>openReview(row);actions.append(open);
      tr.append(selectCell,node('td',row.trigger),meaning,node('td',categoryNames[row.category]||row.category),node('td',row.auto_replace?'Bật':'Tắt'),actions);host.append(tr);
    }
  }
  if(!rows.length){const tr=node('tr'),cell=node('td','Không có mục phù hợp. Thử thay bộ lọc hoặc tải lại.');cell.colSpan=6;cell.className='queue-empty';tr.append(cell);host.append(tr);}
  el('queue-prev').disabled=busy||page===0;el('queue-next').disabled=busy||(page+1)*50>=total;
  el('queue-page').textContent=`Trang ${page+1}/${Math.max(1,Math.ceil(total/50))} · ${total} mục`;
  el('queue-description').textContent=`${el('queue-kind').value==='seeds'?'Từ vựng trong bộ dữ liệu':'Đề xuất từ cộng đồng'} · Chọn cụm chỉ áp dụng trong trang đang xem. Không tự chọn trang khác.`;
  selection();
}
async function loadQueue(){
  if(!allowed)return;saveEdit();const version=++loadVersion;el('queue-reload').disabled=true;
  const filters={kind:el('queue-kind').value,status:el('queue-filter').value,search:el('queue-search').value.trim(),category:el('queue-category').value,offset:page*50,grouped:el('queue-grouped').checked};
  rows=[];selected.clear();edits.clear();closeDetail();render();el('queue-description').textContent='Đang tải hàng chờ…';
  try{localStorage.setItem(filtersKey,JSON.stringify({...filters,compact:el('queue-compact').checked}));}catch{}
  try{
    let data;
    try{data=await store.reviewQueue(filters);advanced=true;}
    catch(error){
      if(!error.message.includes('database cộng đồng'))throw error;
      advanced=false;
      // Existing installations remain usable before running the optional upgrade.
      const token=await store.accessToken(),kind=filters.kind==='seeds'?'intelkb_dictionary':'intelkb_proposals';
      const state=filters.kind==='seeds'?({pending:'draft',accepted:'approved',rejected:'rejected'}[filters.status]):filters.status;
      let all=[];
      for(let offset=0;;offset+=1000){const part=await store.request(`/rest/v1/${kind}?select=*&status=eq.${state}&order=created_at,id&limit=1000&offset=${offset}`,{token});all.push(...part);if(part.length<1000)break;}
      all=all.filter(row=>(!filters.category||row.category===filters.category)&&normalize(row.trigger+' '+row.expansion).includes(normalize(filters.search)));
      if(filters.grouped)all.sort((a,b)=>a.trigger.localeCompare(b.trigger,'vi'));
      data={rows:all.slice(filters.offset,filters.offset+50),total:all.length};
    }
    if(!allowed||version!==loadVersion)return;
    if(page>0 && !data.rows.length){page--;return loadQueue();}
    rows=data.rows;total=data.total;selected.clear();edits.clear();closeDetail();el('review-upgrade').hidden=advanced;
    for(const key of ['seeds','proposals','approved'])el('stat-'+key).textContent=data.counts?.[key]??'—';
    render();status(`Đã tải ${rows.length} mục. Chọn dòng để kiểm tra hoặc chọn nhiều để duyệt theo lô.`);
  }catch(error){if(allowed&&version===loadVersion)status(error.message,true);}
  finally{if(allowed&&version===loadVersion)el('queue-reload').disabled=false;}
}
async function authorize(){hide();if(!store.session)return;try{if(!await store.isAdmin())throw new Error('Tài khoản chưa có quyền kiểm duyệt. Cần được cấp UUID trong intelkb_admins.');allowed=true;el('admin-panel').hidden=false;el('admin-login').hidden=true;el('admin-logout').hidden=false;await loadQueue();}catch(error){hide();status(error.message,true);}}
async function openReview(row){
  saveEdit();current=row;const saved=edits.get(row.id)||row;
  el('review-title').textContent=row.trigger+' →';el('review-expansion').value=saved.expansion;el('review-category').value=saved.category;el('review-auto').checked=saved.auto_replace;el('review-note').value=saved.note||'';
  const lines=[`Bản đang xét: ${row.expansion}`];
  if(row.explanation)lines.push('Giải thích / ví dụ: '+row.explanation);if(row.contributor_name)lines.push('Người đóng góp: '+row.contributor_name);if(row.moderator_note)lines.push('Ghi chú trước đó: '+row.moderator_note);
  el('review-original').textContent=lines.join('\n');el('review-form').hidden=false;el('review-empty').hidden=true;
  el('accept-proposal').hidden=el('reject-proposal').hidden=!canReview(row);render();
  if(window.innerWidth<1000)el('review-form').scrollIntoView({behavior:'smooth',block:'center'});
  if(row.target_id){try{const target=await store.target(row.target_id);if(!allowed||current?.id!==row.id)return;el('review-original').textContent+='\nNghĩa hiện tại: '+(target?target.expansion+' · v'+target.revision:'Mục gốc không còn tồn tại')+'\nĐề xuất dựa trên v'+row.base_revision;}catch(error){if(current?.id===row.id)status(error.message,true);}}
}
function nextRow(delta=1){const index=rows.findIndex(row=>row.id===current?.id);const row=rows[Math.max(0,Math.min(rows.length-1,index+delta))];if(row)openReview(row);}
function prepare(dec,chosen){
  if(busy||!chosen.length)return;saveEdit();
  try{
    batch=chosen.filter(canReview).map(row=>{const draft=edits.get(row.id);return {id:row.id,kind:el('queue-kind').value,revision:row.revision,trigger:row.trigger,expansion:draft?.expansion||row.expansion,note:draft?.note||'',override:dec==='accept'&&draft?validateEntry({...row,...draft}):undefined,row};});
    if(!batch.length)return;
    decision=dec;el('batch-title').textContent=dec==='accept'?'Duyệt và công bố '+batch.length+' mục?':'Từ chối '+batch.length+' mục?';
    el('batch-description').textContent='Kiểm tra các nghĩa dưới đây trước khi xác nhận.';
    el('batch-preview').replaceChildren(...batch.map(item=>node('p',item.trigger+' → '+item.expansion)));
    el('batch-category').value='';el('batch-auto').value='';el('batch-note').value=batch.length===1?batch[0].note:'';
    el('batch-category').disabled=el('batch-auto').disabled=dec!=='accept';
    el('batch-submit').textContent=dec==='accept'?'Xác nhận duyệt':'Xác nhận từ chối';el('batch-dialog').showModal();
  }catch(error){status(error.message,true);}
}
async function confirmBatch(event){
  event.preventDefault();if(busy||!allowed)return;busy=true;el('batch-submit').disabled=true;el('batch-cancel').disabled=true;selection();
  const note=el('batch-note').value,options={};if(decision==='accept'&&el('batch-category').value)options.category=el('batch-category').value;if(decision==='accept'&&el('batch-auto').value==='off')options.auto_replace=false;
  try{
    let report;
    if(advanced){report=await store.reviewBatch(batch.map(({row,note,...item})=>item),decision,note,options);}
    else{
      const reportRows=[];
      for(const [i,item] of batch.entries()){
        if(!allowed)break;status(`Đang xử lý ${i+1}/${batch.length}…`);
        try{await store.review(item.row,item.kind,decision,note,{...item.override,...options});reportRows.push({id:item.id,ok:true});}catch(error){reportRows.push({id:item.id,ok:false,error:error.message});}
      }
      report={rows:reportRows,ok:reportRows.filter(row=>row.ok).length,failed:reportRows.filter(row=>!row.ok).length};
    }
    if(!allowed)return;
    results=report.rows.map(result=>({...result,trigger:batch.find(item=>item.id===result.id)?.trigger}));
    el('review-summary').textContent=`${report.ok} mục thành công · ${report.failed} mục chưa xử lý được.`;
    el('review-result-rows').replaceChildren(...results.map(item=>node('p',`${item.trigger}: ${item.ok?'Đã '+(decision==='accept'?'duyệt':'từ chối'):item.error}`,item.ok?'result-ok':'result-error')));
    el('review-results').hidden=false;el('batch-dialog').close();await loadQueue();
    status(`Đã xử lý lượt duyệt: ${report.ok} thành công, ${report.failed} lỗi. Xem báo cáo phía dưới.`,report.failed>0);
  }catch(error){if(allowed){el('batch-dialog').close();status('Chưa xác nhận được toàn bộ kết quả. Hãy tải lại trước khi thử lại. '+error.message,true);}}
  finally{busy=false;el('batch-submit').disabled=false;el('batch-cancel').disabled=false;selection();}
}
el('admin-login').onsubmit=async event=>{event.preventDefault();el('login-button').disabled=true;try{await store.signIn(el('admin-email').value.trim(),el('admin-password').value);el('admin-password').value='';await authorize();}catch(error){status(error.message,true);}finally{el('login-button').disabled=false;}};
el('admin-logout').onclick=async()=>{hide();await store.signOut();status('Đã đăng xuất.');};
for(const id of ['queue-kind','queue-filter','queue-category','queue-grouped'])el(id).onchange=()=>{if(!busy){page=0;loadQueue();}};
el('queue-search').oninput=()=>{clearTimeout(searchTimer);searchTimer=setTimeout(()=>{if(!busy){page=0;loadQueue();}},250);};
el('queue-compact').onchange=()=>el('review-table').classList.toggle('compact',el('queue-compact').checked);
el('queue-reload').onclick=()=>{if(!busy)loadQueue();};el('queue-prev').onclick=()=>{if(!busy){page--;loadQueue();}};el('queue-next').onclick=()=>{if(!busy){page++;loadQueue();}};
el('select-page').onclick=()=>{rows.filter(canReview).forEach(row=>selected.set(row.id,row));selection();};el('clear-selection').onclick=()=>{selected.clear();selection();};
el('bulk-accept').onclick=()=>prepare('accept',[...selected.values()]);el('bulk-reject').onclick=()=>prepare('reject',[...selected.values()]);
el('review-form').onsubmit=event=>{event.preventDefault();if(current)prepare('accept',[current]);};el('reject-proposal').onclick=()=>{if(current)prepare('reject',[current]);};
el('review-form').oninput=saveEdit;el('cancel-review').onclick=()=>{saveEdit();closeDetail();render();};el('review-next').onclick=()=>nextRow();
el('batch-confirm').onsubmit=confirmBatch;el('batch-cancel').onclick=()=>el('batch-dialog').close();
el('batch-dialog').addEventListener('cancel',event=>{if(busy)event.preventDefault();});
el('export-results').onclick=()=>{const url=URL.createObjectURL(new Blob([JSON.stringify(results,null,2)],{type:'application/json'}));const a=node('a');a.href=url;a.download='intelkb-review-results.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);};
document.addEventListener('keydown',event=>{if(!allowed||busy||el('batch-dialog').open||/INPUT|TEXTAREA|SELECT/.test(event.target.tagName))return;if(event.key==='j'){event.preventDefault();nextRow();}if(event.key==='k'){event.preventDefault();nextRow(-1);}if(event.altKey&&event.key==='Enter'&&current){event.preventDefault();prepare('accept',[current]);}});
try{const saved=JSON.parse(localStorage.getItem(filtersKey));if(saved){for(const [id,key] of [['queue-kind','kind'],['queue-filter','status'],['queue-category','category']])if(saved[key])el(id).value=saved[key];el('queue-search').value=saved.search||'';el('queue-grouped').checked=saved.grouped!==false;el('queue-compact').checked=saved.compact!==false;el('review-table').classList.toggle('compact',el('queue-compact').checked);}}catch{}
authorize();
