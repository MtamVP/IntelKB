import {CommunityStore} from './community-store.mjs';
import {validateEntry} from './dictionary-store.mjs';
import {groupReviewRows} from './contribution-tools.mjs';
import {normalize} from './engine.mjs';
import {reviewTargets,entryDiff,nextAfterReview,reviewError,makeReviewDraft,dirtyReviewDraft,staleReviewDraft,modeDefaultGaps} from './review-actions.mjs';
const el=id=>document.getElementById(id),store=new CommunityStore();
const categoryNames={chat:'Nhắn tin',profanity:'Từ tục',euphemism:'Nói nhẹ',english:'Tiếng Anh',game:'Game'};
let allowed=false,rows=[],page=0,total=0,current=null,advanced=true,busy=false,loadVersion=0,searchTimer,decision='accept',batch=[],results=[];
const selected=new Map(),edits=new Map(),styleChoices=new Map();let contextRows=[],lastUndo=null,publishedSaveAttempt=null,modeGaps=[],modeCatalogue=[],modeStatsDirty=true;
const filtersKey='intelkb.review.filters.v2';
function status(message,error=false){el('admin-status').textContent=message;el('admin-status').classList.toggle('error',error);}
function node(tag,text,cls=''){const element=document.createElement(tag);if(text!==undefined)element.textContent=text;if(cls)element.className=cls;return element;}
function canReview(row){return ['draft','pending'].includes(row.status);}
function closeDetail(){current=null;el('review-form').hidden=true;el('review-empty').hidden=false;}
function hide(){allowed=false;loadVersion++;contextRows=[];lastUndo=null;publishedSaveAttempt=null;modeGaps=[];modeCatalogue=[];modeStatsDirty=true;styleChoices.clear();selected.clear();edits.clear();rows=[];closeDetail();el('queue-list').replaceChildren();el('admin-panel').hidden=true;el('admin-login').hidden=false;el('admin-logout').hidden=true;el('review-results').hidden=true;}
function selection(){
  for(const id of ['queue-kind','queue-filter','queue-search','queue-category','queue-grouped','queue-compact','queue-reload'])el(id).disabled=busy;
  el('stat-unsaved').textContent=edits.size;for(const id of ['open-pending','open-mode-gaps','open-unsaved'])el(id).disabled=busy;el('open-unsaved').disabled=busy||!edits.size;
  const n=selected.size;el('selected-count').textContent=n?`${n} mục đã chọn · trang hiện tại`:'Chưa chọn mục';
  for(const id of ['bulk-accept','bulk-reject','clear-selection'])el(id).disabled=!n||busy;
  el('select-page').disabled=busy||!rows.some(canReview);
  for(const box of el('queue-list').querySelectorAll('input[data-id]')){box.checked=selected.has(box.dataset.id);box.disabled=busy||!canReview(rows.find(row=>row.id===box.dataset.id));}
  for(const checkbox of el('queue-list').querySelectorAll('input[data-group]')){
    const group=rows.filter(row=>normalize(row.trigger)===checkbox.dataset.group&&canReview(row));
    checkbox.disabled=busy||!group.length;
    const count=group.filter(row=>selected.has(row.id)).length;checkbox.checked=Boolean(group.length)&&count===group.length;checkbox.indeterminate=count>0&&count<group.length;
  }
  for(const row of el('queue-list').querySelectorAll('tr[data-review-id]')){const checked=selected.has(row.dataset.reviewId);row.classList.toggle('selected',checked);row.setAttribute('aria-selected',String(checked));}
  for(const button of el('queue-list').querySelectorAll('button'))button.disabled=busy;
  el('review-form').inert=busy;el('batch-options').inert=busy;el('style-review').inert=busy;el('undo-review').disabled=busy||!lastUndo?.undo_available;
  el('save-published').disabled=busy||Boolean(current&&staleReviewDraft(current,edits.get(current.id)));
  if(current){const count=selected.has(current.id)?selected.size:1;el('accept-proposal').textContent=`Duyệt ${count>1?count+' mục':'mục này'}`;el('reject-proposal').textContent=`Từ chối${count>1?' '+count+' mục':''}`;}
  for(const button of el('queue-list').querySelectorAll('[data-decision]')){const count=selected.has(button.dataset.rowId)?selected.size:1;button.textContent=(button.dataset.decision==='accept'?'Duyệt':'Từ chối')+(count>1?' ('+count+')':'');button.title=count>1?`Áp dụng cho ${count} mục đang chọn`:'Chỉ áp dụng cho dòng này';}
  el('queue-prev').disabled=busy||page===0;el('queue-next').disabled=busy||(page+1)*50>=total;
}
function saveEdit(){if(!current)return;const draft=makeReviewDraft(current,{trigger:current.trigger,expansion:el('review-expansion').value,category:el('review-category').value,auto_replace:el('review-auto').checked,note:el('review-note').value},edits.get(current.id));if(dirtyReviewDraft(draft))edits.set(current.id,draft);else edits.delete(current.id);}
function candidates(){
 const map=new Map(contextRows.filter(row=>row.status==='approved').map(row=>[row.id,{...row,kind:'approved'}]));
 for(const row of rows.filter(canReview))map.set(row.id,{...row,...edits.get(row.id),kind:el('queue-kind').value});
 return [...map.values()];
}
function renderStyles(){
 const host=el('style-groups');host.replaceChildren();
 for(const [key,group] of groupReviewRows(candidates())){
  if(group.length<2)continue;
  const box=node('section',undefined,'style-group');box.dataset.alias=key;box.append(node('strong',key+' · '+group.length+' nghĩa liên quan'));
  const profane=group.filter(row=>row.category==='profanity'),safe=group.filter(row=>row.category!=='profanity');
  const selects={};
  for(const mode of ['direct','gentle']){
   const pool=mode==='direct'?(profane.length?profane:safe):safe,label=node('label',mode==='direct'?'Nhắn tục':'Nhắn nhẹ');
   if(!pool.length){label.append(node('small','Không có nghĩa phù hợp'));box.append(label);continue;}
   const select=node('select');select.setAttribute('aria-label',`${mode==='direct'?'Ưu tiên nhắn tục':'Ưu tiên nhắn nhẹ'} cho ${key}`);
   const auto=node('option',pool.length===1?'Tự chọn: '+pool[0].expansion:'Chọn một nghĩa ưu tiên / giữ bản đã chọn');auto.value='';select.append(auto);
   for(const row of pool){
    const bundled=row.source==='bootstrap'&&['seeds','approved'].includes(row.kind);
    const label=bundled?'Đã duyệt · Bộ có sẵn':row.kind==='approved'?'Đã duyệt':'Chờ duyệt';
    const option=node('option',row.expansion+' · '+label);option.value=row.kind+':'+row.id;select.append(option);
   }
   const chosen=styleChoices.get(key+':'+mode)||group.find(row=>row[mode==='direct'?'auto_direct':'auto_gentle']);
   if(chosen&&pool.some(row=>row.kind===chosen.kind&&row.id===chosen.id))select.value=chosen.kind+':'+chosen.id;else styleChoices.delete(key+':'+mode);
   select.onchange=()=>{const row=pool.find(row=>row.kind+':'+row.id===select.value);if(row){styleChoices.set(key+':'+mode,{trigger:key,mode,kind:row.kind,id:row.id});if(row.kind!=='approved')selected.set(row.id,rows.find(item=>item.id===row.id));}else styleChoices.delete(key+':'+mode);selection();};
   selects[mode]=select;label.append(select);box.append(label);
  }
  const save=node('button','Lưu ưu tiên cho nghĩa đã công bố');save.type='button';save.disabled=!group.some(row=>row.kind==='approved');
  save.onclick=async()=>{
   const chosen=mode=>group.find(row=>row.kind+':'+row.id===selects[mode]?.value);
   const d=chosen('direct'),g=chosen('gentle');if([d,g].some(row=>row&&row.kind!=='approved')){status([d,g].some(row=>row&&row.kind==='proposals')?'Nghĩa chờ duyệt sẽ được đặt ưu tiên khi bạn duyệt những dòng đã chọn.':'Đã chọn nghĩa từ bộ có sẵn. Bấm Duyệt trên dòng đã chọn để lưu ưu tiên và đồng bộ trạng thái với Supabase.',true);return;}
   if(busy)return;busy=true;selection();try{const report=await store.setStyleDefaults(key,d?.id,g?.id);if(!allowed)return;lastUndo=report;modeStatsDirty=true;el('review-results').hidden=false;el('review-summary').textContent='Đã lưu nghĩa ưu tiên theo chế độ.';await loadQueue();}catch(error){status(error.message,true);}finally{busy=false;selection();}
  };box.append(save);host.append(box);
 }
 if(!host.childElementCount)host.append(node('p','Không có nhóm nhiều nghĩa trong trang này.'));
}
function diffView(before,after){
 const host=node('div',undefined,'entry-diff'),labels={trigger:'Viết tắt',expansion:'Nghĩa',category:'Nhóm',auto_replace:'Tự động điền'};
 const format=(key,value)=>key==='auto_replace'?(value?'Bật':'Tắt'):key==='category'?(categoryNames[value]||value):value;
 for(const change of entryDiff(before,after)){const line=node('div');line.append(node('small',labels[change.key]),node('del',format(change.key,change.before)),node('span',' → '),node('ins',format(change.key,change.after)));host.append(line);}
 return host;
}
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
      const tr=node('tr');tr.dataset.reviewId=row.id;if(current?.id===row.id)tr.classList.add('current');
      if(canReview(row)){tr.tabIndex=0;tr.setAttribute('aria-label',`Chọn ${row.trigger}: ${row.expansion}`);const toggle=()=>{if(busy)return;selected.has(row.id)?selected.delete(row.id):selected.set(row.id,row);selection();};tr.onclick=event=>{if(!event.target.closest('button,input,label,a,select,textarea')&&!window.getSelection()?.toString())toggle();};tr.onkeydown=event=>{if(event.target===tr&&!event.altKey&&!event.ctrlKey&&[' ','Enter'].includes(event.key)){event.preventDefault();toggle();}};}

      const selectCell=node('td'),check=node('input');check.type='checkbox';check.dataset.id=row.id;check.disabled=busy||!canReview(row);check.setAttribute('aria-label',`Chọn ${row.trigger}: ${row.expansion}`);check.onchange=()=>{check.checked?selected.set(row.id,row):selected.delete(row.id);selection();};selectCell.append(check);
      const draft=edits.get(row.id),display=draft?{...row,...draft}:row;const meaning=node('td');meaning.append(node('span',display.expansion));if(draft)meaning.append(node('small',staleReviewDraft(row,draft)?'Bản trên máy chủ đã thay đổi · bản sửa vẫn được giữ':'Có chỉnh sửa chưa lưu'));
      meaning.append(diffView(row.action==='edit'?contextRows.find(item=>item.id===row.target_id):row,display));
      if(row.explanation)meaning.append(node('small',row.explanation));
      const meta=[row.action==='edit'?'Sửa nghĩa':row.action==='add_meaning'?'Thêm nghĩa':row.source==='bootstrap'?'Khởi tạo':'Từ mới'];
      if(row.created_at)meta.push(new Date(row.created_at).toLocaleDateString('vi-VN'));
      meaning.append(node('small',meta.join(' · ')));
      const actions=node('td'),open=node('button','Xem / sửa');open.type='button';open.onclick=()=>openReview(row);actions.className='row-actions';actions.append(open);
      if(canReview(row))for(const dec of ['accept','reject']){const button=node('button',dec==='accept'?'Duyệt':'Từ chối',dec);button.type='button';button.dataset.decision=dec;button.dataset.rowId=row.id;button.setAttribute('aria-label',`${dec==='accept'?'Duyệt':'Từ chối'} từ dòng ${row.trigger}: ${row.expansion}`);button.onclick=()=>prepare(dec,reviewTargets(rows,selected,row.id));actions.append(button);}
      tr.append(selectCell,node('td',row.trigger),meaning,node('td',categoryNames[display.category]||display.category),node('td',(display.auto_replace?'Bật':'Tắt')+(display.auto_direct?' · Nhắn tục':'')+(display.auto_gentle?' · Nhắn nhẹ':'')),actions);host.append(tr);
    }
  }
  if(!rows.length){const tr=node('tr'),cell=node('td','Không có mục phù hợp. Thử thay bộ lọc hoặc tải lại.');cell.colSpan=6;cell.className='queue-empty';tr.append(cell);host.append(tr);}
  el('queue-prev').disabled=busy||page===0;el('queue-next').disabled=busy||(page+1)*50>=total;
  el('queue-page').textContent=`Trang ${page+1}/${Math.max(1,Math.ceil(total/50))} · ${total} mục`;
  el('queue-description').textContent=`${el('queue-kind').value==='seeds'?'Từ vựng trong bộ dữ liệu':'Đề xuất từ cộng đồng'} · Chọn cụm chỉ áp dụng trong trang đang xem. Không tự chọn trang khác.`;
  renderStyles();selection();
}
async function loadQueue(){
  if(!allowed)return;saveEdit();const version=++loadVersion;el('queue-reload').disabled=true;
  const filters={kind:el('queue-kind').value,status:el('queue-filter').value,search:el('queue-search').value.trim(),category:el('queue-category').value,offset:page*50,grouped:el('queue-grouped').checked};
  rows=[];contextRows=[];selected.clear();styleChoices.clear();closeDetail();render();el('queue-description').textContent='Đang tải hàng chờ…';
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
    rows=data.rows;total=data.total;selected.clear();styleChoices.clear();closeDetail();
    const context=await Promise.allSettled([store.reviewContext(rows.map(row=>({id:row.id,kind:filters.kind}))),store.lastReview(),modeStatsDirty?store.loadCatalogue():Promise.resolve(null)]);
    if(!allowed||version!==loadVersion)return;
    contextRows=context[0].status==='fulfilled'?context[0].value:[];
    if(context[1].status==='fulfilled')lastUndo=context[1].value;
    el('review-upgrade').hidden=context.slice(0,2).every(result=>result.status==='fulfilled');
    if(context[2].status==='fulfilled'&&context[2].value){modeCatalogue=context[2].value;modeGaps=modeDefaultGaps(modeCatalogue);modeStatsDirty=false;el('stat-mode-gaps').textContent=modeGaps.length;}else if(context[2].status==='rejected')el('stat-mode-gaps').textContent='—';
    if(lastUndo?.undo_available){el('review-results').hidden=false;if(!el('review-summary').textContent)el('review-summary').textContent='Có lượt kiểm duyệt gần đây có thể hoàn tác.';}
    el('stat-proposals').textContent=data.counts?.proposals??'—';
    render();status(`Đã tải ${rows.length} mục. Bấm nền dòng để chọn; Duyệt / Từ chối trên dòng đã chọn áp dụng cho toàn bộ mục đang chọn.`);
  }catch(error){if(allowed&&version===loadVersion)status(error.message,true);}
  finally{if(allowed&&version===loadVersion)el('queue-reload').disabled=false;}
}
async function authorize(){hide();if(!store.session)return;try{if(!await store.isAdmin())throw new Error('Tài khoản chưa có quyền kiểm duyệt. Cần được cấp UUID trong intelkb_admins.');allowed=true;el('admin-panel').hidden=false;el('admin-login').hidden=true;el('admin-logout').hidden=false;await loadQueue();}catch(error){hide();status(error.message,true);}}
async function openReview(row){
  saveEdit();current=row;const saved=edits.get(row.id)||row;
  el('review-title').textContent=row.trigger+' →';el('review-expansion').value=saved.expansion;el('review-category').value=saved.category;el('review-auto').checked=saved.auto_replace;el('review-note').value=saved.note||'';
  const lines=[`Bản đang xét: ${row.expansion}`];
  if(row.explanation)lines.push('Giải thích / ví dụ: '+row.explanation);if(row.contributor_name)lines.push('Người đóng góp: '+row.contributor_name);if(row.moderator_note)lines.push('Ghi chú trước đó: '+row.moderator_note);
  el('review-original').textContent=lines.join('\n');el('review-original').append(diffView(row.action==='edit'?contextRows.find(item=>item.id===row.target_id):row,saved));el('review-form').hidden=false;el('review-empty').hidden=true;
  el('accept-proposal').hidden=el('reject-proposal').hidden=!canReview(row);
  el('save-published').hidden=!(el('queue-kind').value==='seeds'&&row.status==='approved');el('published-save-help').hidden=el('save-published').hidden;el('published-save-status').hidden=true;el('discard-review-edit').hidden=!edits.has(row.id);render();
  if(staleReviewDraft(row,edits.get(row.id)))status('Mục này đã được sửa trên máy chủ. Bản bạn đang nhập vẫn được giữ; bấm Bỏ bản sửa, xem dữ liệu mới trước khi sửa lại để tránh ghi đè.',true);
  if(window.innerWidth<1000)el('review-form').scrollIntoView({behavior:'smooth',block:'center'});
  if(row.target_id){try{const target=await store.target(row.target_id);if(!allowed||current?.id!==row.id)return;el('review-original').textContent+='\nNghĩa hiện tại: '+(target?target.trigger+' → '+target.expansion+' · v'+target.revision:'Mục gốc không còn tồn tại')+'\nĐề xuất dựa trên v'+row.base_revision;}catch(error){if(current?.id===row.id)status(error.message,true);}}
}
function nextRow(delta=1){const index=rows.findIndex(row=>row.id===current?.id);const row=rows[Math.max(0,Math.min(rows.length-1,index+delta))];if(row)openReview(row);}
function prepare(dec,chosen){
  if(busy||!chosen.length)return;saveEdit();
  try{
    batch=chosen.filter(canReview).map(row=>{const draft=edits.get(row.id);if(dec==='accept'&&staleReviewDraft(row,draft))throw new Error('Bản sửa '+row.trigger+' đã cũ. Mở mục và bỏ bản sửa cũ trước khi duyệt lại.');return {id:row.id,kind:el('queue-kind').value,revision:row.revision,trigger:row.trigger,expansion:draft?.expansion||row.expansion,note:draft?.note||'',override:dec==='accept'&&draft?validateEntry({...row,...draft}):undefined,row};});
    if(!batch.length)return;
    decision=dec;confirmBatch();
  }catch(error){status(error.message,true);}
}
async function confirmBatch(){
  if(busy||!allowed)return;busy=true;selection();
  const note=el('batch-note').value||(batch.length===1?batch[0].note:''),options={};if(decision==='accept'&&el('batch-category').value)options.category=el('batch-category').value;if(decision==='accept'&&el('batch-auto').value==='off')options.auto_replace=false;
  try{
    const affected=new Set(batch.map(item=>normalize(item.trigger)));
    for(const item of batch){const target=contextRows.find(row=>row.id===item.row.target_id);if(target)affected.add(normalize(target.trigger));}
    const choices=[...styleChoices.values()].filter(choice=>affected.has(choice.trigger));
    const processed=new Set(batch.map(item=>item.id)),nextId=nextAfterReview(rows,processed),scroll=el('queue-list').closest('.review-table-wrap').scrollTop;
    const report=await store.commitReview(crypto.randomUUID(),batch.map(({row,note,...item})=>item),decision,note,options,choices);
    if(!allowed)return;lastUndo=report;modeStatsDirty=true;for(const result of report.rows)if(result.ok){edits.delete(result.id);if(current?.id===result.id)closeDetail();}
    results=report.rows.map(result=>({...result,trigger:batch.find(item=>item.id===result.id)?.trigger}));
    el('review-summary').textContent=`${report.ok} mục thành công · ${report.failed} mục chưa xử lý được.`;
    el('review-result-rows').replaceChildren(...results.map(item=>node('p',`${item.trigger}: ${item.ok?'Đã '+(decision==='accept'?'duyệt':'từ chối'):item.error}`,item.ok?'result-ok':'result-error')));
    el('review-results').hidden=false;await loadQueue();
    const next=rows.find(row=>report.rows.some(item=>item.id===row.id&&!item.ok))||rows.find(row=>row.id===nextId)||rows[0];
    if(next){await openReview(next);el('queue-list').closest('.review-table-wrap').scrollTop=scroll;}
    status(`Đã xử lý lượt duyệt: ${report.ok} thành công, ${report.failed} lỗi. Xem báo cáo phía dưới.`,report.failed>0);
  }catch(error){if(allowed){const failure=reviewError(error);status(failure.message,true);el('review-summary').textContent=failure.message;el('review-result-rows').replaceChildren();el('review-results').hidden=false;if(failure.needsChoice){el('style-review').open=true;el('style-review').scrollIntoView({behavior:'smooth',block:'center'});}else el('admin-status').scrollIntoView({behavior:'smooth',block:'center'});}}
  finally{busy=false;selection();}
}
el('undo-review').onclick=async()=>{if(busy||!lastUndo?.undo_available)return;busy=true;selection();try{await store.undoReview(lastUndo.action_id);if(!allowed)return;lastUndo=null;modeStatsDirty=true;el('review-summary').textContent='Đã hoàn tác lượt cuối; dữ liệu trở về trạng thái trước lượt duyệt với phiên bản mới.';await loadQueue();status('Đã hoàn tác. Các thay đổi mới hơn không bị ghi đè.');}catch(error){status(error.message,true);}finally{busy=false;selection();}};
el('admin-login').onsubmit=async event=>{event.preventDefault();el('login-button').disabled=true;try{await store.signIn(el('admin-email').value.trim(),el('admin-password').value);el('admin-password').value='';await authorize();}catch(error){status(error.message,true);}finally{el('login-button').disabled=false;}};
el('admin-logout').onclick=async()=>{hide();await store.signOut();status('Đã đăng xuất.');};
for(const id of ['queue-kind','queue-filter','queue-category','queue-grouped'])el(id).onchange=()=>{if(!busy){page=0;loadQueue();}};

async function openShortcut(kind,statusValue,search=''){
 if(busy||!allowed)return;el('queue-kind').value=kind;el('queue-filter').value=statusValue;el('queue-search').value=search;el('queue-category').value='';page=0;await loadQueue();
}
el('open-pending').onclick=()=>openShortcut('proposals','pending');
el('open-mode-gaps').onclick=async()=>{
 if(busy||!allowed)return;
 if(!modeGaps.length){await openShortcut('seeds','accepted');status('Đã mở các mục công bố. Các nhóm nhiều nghĩa có thể được kiểm tra và đổi ưu tiên trong phần theo chế độ.');return;}
 const gap=modeGaps[0];await openShortcut('seeds','accepted',gap.trigger);if(!allowed)return;contextRows=[...new Map([...modeCatalogue.filter(row=>normalize(row.trigger)===gap.trigger),...contextRows].map(row=>[row.id,row])).values()];renderStyles();el('style-review').open=true;const group=[...el('style-groups').children].find(node=>node.dataset.alias===gap.trigger);(group||el('style-review')).scrollIntoView({behavior:'smooth',block:'center'});status(`Nhóm “${gap.trigger}” cần chọn nghĩa ưu tiên cho ${gap.modes.map(mode=>mode==='direct'?'nhắn tục':'nhắn nhẹ').join(' và ')}.`);
};
el('open-unsaved').onclick=async()=>{
 if(busy||!allowed||!edits.size)return;
 const visible=rows.find(row=>edits.has(row.id));if(visible){await openReview(visible);el('review-form').scrollIntoView({behavior:'smooth',block:'center'});return;}
 const [id,draft]=edits.entries().next().value,base=JSON.parse(draft._base),kind=['draft','approved'].includes(base.status)?'seeds':'proposals';
 await openShortcut(kind,base.status==='approved'?'accepted':'pending',base.trigger);const row=rows.find(row=>row.id===id);
 if(row)await openReview(row);else status('Bản sửa vẫn được giữ trong phiên, nhưng mục này không còn ở hàng chờ tương ứng. Hãy đối chiếu trạng thái hiện tại trước khi lưu.',true);
};

el('queue-search').oninput=()=>{clearTimeout(searchTimer);searchTimer=setTimeout(()=>{if(!busy){page=0;loadQueue();}},250);};
el('queue-compact').onchange=()=>el('review-table').classList.toggle('compact',el('queue-compact').checked);
el('queue-reload').onclick=()=>{if(!busy){modeStatsDirty=true;loadQueue();}};el('queue-prev').onclick=()=>{if(!busy){page--;loadQueue();}};el('queue-next').onclick=()=>{if(!busy){page++;loadQueue();}};
el('select-page').onclick=()=>{rows.filter(canReview).forEach(row=>selected.set(row.id,row));selection();};el('clear-selection').onclick=()=>{selected.clear();selection();};
el('bulk-accept').onclick=()=>prepare('accept',[...selected.values()]);el('bulk-reject').onclick=()=>prepare('reject',[...selected.values()]);
async function savePublished(){
 if(busy||!allowed||!current||current.status!=='approved'||el('queue-kind').value!=='seeds')return;
 saveEdit();const row=current,draft=edits.get(row.id)||{...row,note:''};let entry;
 if(staleReviewDraft(row,edits.get(row.id))){status('Bản sửa đã cũ. Bỏ bản sửa cũ và đối chiếu dữ liệu mới trước khi lưu.',true);return;}
 try{entry=validateEntry({...row,...draft});}catch(error){status(error.message,true);return;}
 const signature=JSON.stringify([row.id,row.revision,entry,draft.note]);
 if(publishedSaveAttempt?.signature!==signature)publishedSaveAttempt={signature,receipt:crypto.randomUUID()};
 busy=true;selection();el('save-published').textContent='Đang lưu…';el('published-save-status').hidden=false;el('published-save-status').textContent='Đang lưu vào Supabase…';
 try{
  const report=await store.savePublished(row,entry,draft.note,publishedSaveAttempt.receipt);if(!allowed)return;publishedSaveAttempt=null;lastUndo=report;modeStatsDirty=true;edits.delete(row.id);current=null;
  const remaining=new Map(edits);await loadQueue();for(const [id,draft] of remaining)if(rows.some(item=>item.id===id))edits.set(id,draft);
  const updated=rows.find(item=>item.id===row.id);if(updated)await openReview(updated);else render();
  status('Đã lưu thay đổi vào từ điển. Bạn có thể hoàn tác lượt lưu này.');el('published-save-status').hidden=false;el('published-save-status').textContent='Đã lưu vào Supabase.';
 }catch(error){if(allowed){const message=error.code==='PGRST202'?'Cần chạy SQL lưu mục đã duyệt: published-edit-upgrade.sql trong Supabase SQL Editor. Thay đổi của bạn vẫn được giữ trong form.':reviewError(error).message;status(message,true);el('published-save-status').hidden=false;el('published-save-status').textContent=message;}}
 finally{busy=false;el('save-published').textContent='Lưu thay đổi';selection();}
}
el('save-published').onclick=savePublished;
el('review-form').onsubmit=event=>{event.preventDefault();if(current?.status==='approved'&&el('queue-kind').value==='seeds')savePublished();else if(current)prepare('accept',reviewTargets(rows,selected,current.id));};el('reject-proposal').onclick=()=>{if(current)prepare('reject',reviewTargets(rows,selected,current.id));};
el('review-form').oninput=()=>{saveEdit();el('discard-review-edit').hidden=!edits.has(current?.id);render();};
el('discard-review-edit').onclick=()=>{if(!current||busy)return;const row=current;edits.delete(row.id);publishedSaveAttempt=null;current=null;openReview(row);};
window.addEventListener('beforeunload',event=>{if([...edits.values()].some(dirtyReviewDraft)){event.preventDefault();event.returnValue='';}});el('cancel-review').onclick=()=>{saveEdit();closeDetail();render();};el('review-next').onclick=()=>nextRow();
el('export-results').onclick=()=>{const url=URL.createObjectURL(new Blob([JSON.stringify(results,null,2)],{type:'application/json'}));const a=node('a');a.href=url;a.download='intelkb-review-results.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);};
document.addEventListener('keydown',event=>{if(!allowed||busy||/INPUT|TEXTAREA|SELECT/.test(event.target.tagName))return;if(event.key==='j'){event.preventDefault();nextRow();}if(event.key==='k'){event.preventDefault();nextRow(-1);}if(event.altKey&&event.key==='Enter'&&current){event.preventDefault();prepare('accept',reviewTargets(rows,selected,current.id));}});
try{const saved=JSON.parse(localStorage.getItem(filtersKey));if(saved){for(const [id,key] of [['queue-kind','kind'],['queue-filter','status'],['queue-category','category']])if(saved[key])el(id).value=saved[key];el('queue-search').value=saved.search||'';el('queue-grouped').checked=saved.grouped!==false;el('queue-compact').checked=saved.compact!==false;el('review-table').classList.toggle('compact',el('queue-compact').checked);}}catch{}
authorize();
