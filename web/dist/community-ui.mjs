import { CommunityStore } from './community-store.mjs';
import { publicCatalogue, filterCatalogue, keyboardDictionary, isBundledEntry } from './catalogue.mjs';
import {findTriggerMatches,parseContributions,classifyContribution} from './contribution-tools.mjs';

export function mountDictionary(baseWords,onChange) {
  const get=id=>document.getElementById(id), store=new CommunityStore();
  let catalogue=publicCatalogue(baseWords,[]), mode='sample',page=0,target=null,action='new',draftReceipt=null;
  const pageSize=40,names={chat:'Nhắn tin',profanity:'Từ tục',euphemism:'Nói nhẹ',english:'Tiếng Anh',game:'Game'};
  let resolved={action:'new',target:null};
  let entryMode='single',sending=false,checkTimer,checkVersion=0,blocked=false,existingPair=null;
  const composerKey='intelkb.contribution.composer.v2';
  function status(text,error=false){get('dictionary-status').textContent=text;get('dictionary-status').classList.toggle('error',error);}
  function publicError(error){
    if(/Từ viết tắt|Nghĩa đầy đủ|Hãy chọn nhóm|cần khác|Ghi chú tối đa/.test(error.message))return error.message;
    if(error.message.includes('database cộng đồng'))return 'Từ điển cộng đồng chưa được kích hoạt.';
    if(error.message.includes('identical proposal')||error.message.includes('intelkb_pending_proposal_unique'))return 'Đã có một đóng góp giống như vậy đang chờ duyệt.';
    if(error.message.includes('already published')||error.message.includes('No changes'))return 'Toàn bộ thông tin đã có sẵn. Hãy thay đổi nghĩa, nhóm hoặc tự động điền trước khi gửi.';
    if(error.message.includes('Entry changed')||error.message.includes('Target no longer'))return 'Mục từ đã thay đổi. Tải lại danh sách và góp ý trên bản mới nhé.';
    return 'Chưa kết nối được hệ thống đóng góp. Hãy thử lại sau.';
  }
  function resetForm(clearSaved=false){get('dictionary-form').reset();target=null;action='new';draftReceipt=null;get('entry-trigger').readOnly=false;get('proposal-kind').textContent='Đề xuất từ mới';get('cancel-edit').hidden=true;get('entry-many').disabled=false;get('entry-save-state').textContent='';if(clearSaved)try{localStorage.removeItem(composerKey);}catch{}setEntryMode('single');updateEditor();}
  function editorInput(){return {trigger:get('entry-trigger').value,expansion:get('entry-expansion').value,category:get('entry-category').value,auto_replace:get('entry-auto').checked};}
  function setEntryMode(mode){
    entryMode=mode;get('single-entry').hidden=mode!=='single';get('many-entry').hidden=mode!=='many';
    get('entry-single').setAttribute('aria-pressed',mode==='single');get('entry-many').setAttribute('aria-pressed',mode==='many');
    get('entry-trigger').required=mode==='single';get('entry-expansion').required=mode==='single';updateEditor();
    get('entry-auto').disabled=mode==='many';
  }
  function batchRows(){return parseContributions(get('entry-lines').value,catalogue,get('entry-category').value);}
  function renderTriggerMatches(){
    const result=findTriggerMatches(catalogue,get('entry-trigger').value),host=get('entry-match-list');host.replaceChildren();
    get('entry-lookup').hidden=!result.total;
    get('entry-match-count').textContent=result.exact
      ?`“${result.query}” đã có ${result.exact} nghĩa${result.total>result.exact?` · ${result.total-result.exact} mục gần khớp khác`:''}.`
      :`${result.total} mục chứa “${result.query}” · chưa có viết tắt khớp hoàn toàn.`;
    for(const row of result.rows){
      const item=document.createElement('li'),copy=document.createElement('div'),word=document.createElement('strong'),meaning=document.createElement('span'),badge=document.createElement('small'),edit=document.createElement('button');
      word.textContent=row.trigger;meaning.textContent=' → '+row.expansion;badge.textContent=(isBundledEntry(row)?'Đã duyệt · Bộ có sẵn':'Đã duyệt · Cộng đồng')+' · Tự động điền: '+(row.auto_replace?'Bật':'Tắt')+(row.auto_direct?' · Ưu tiên nhắn tục':'')+(row.auto_gentle?' · Ưu tiên nhắn nhẹ':'');copy.append(word,meaning,badge);
      edit.type='button';edit.textContent='Góp ý';edit.setAttribute('aria-label',`Góp ý mục có sẵn ${row.trigger}: ${row.expansion}`);edit.onclick=()=>startProposal(row,'edit');item.tabIndex=0;item.setAttribute('role','group');item.setAttribute('aria-label',`Góp ý ${row.trigger}: ${row.expansion}`);item.onclick=event=>{if(!event.target.closest('button')&&!window.getSelection()?.toString())startProposal(row,'edit');};item.onkeydown=event=>{if(event.target===item&&['Enter',' '].includes(event.key)){event.preventDefault();startProposal(row,'edit');}};item.append(copy,edit);host.append(item);
    }
    get('entry-match-all').hidden=result.total<=result.rows.length;
    get('entry-match-all').textContent='Mở bảng tra cứu đầy đủ ↗';
  }
  function updateEditor(){
    clearTimeout(checkTimer);const version=++checkVersion;blocked=false;existingPair=null;get('entry-use-existing').hidden=true;
    if(entryMode==='many'){
      const rows=batchRows(),host=get('entry-lines-preview');host.replaceChildren();
      for(const row of rows){const item=document.createElement('p');item.className=row.error?'invalid':'valid';item.textContent=`${row.line}. ${row.value?row.value.trigger+' → '+row.value.expansion:''} · ${row.error||(row.context.action==='edit'?'Chỉnh sửa · '+names[row.value.category]+' · tự động điền: '+(row.value.auto_replace?'Bật':'Tắt'):'Sẵn sàng')}`;host.append(item);}
      const valid=rows.filter(row=>!row.error);get('save-entry').textContent=`Gửi ${valid.length} đề xuất`;get('save-entry').disabled=sending||!valid.length;return;
    }
    get('save-entry').textContent=action==='edit'?'Gửi góp ý sửa':'Gửi đề xuất';
    renderTriggerMatches();
    const value=editorInput(),message=get('entry-duplicate');
    get('entry-auto-current').textContent=(target?`Hiện tại: ${target.auto_replace?'Bật':'Tắt'}. `:'')+`Đề xuất: ${value.auto_replace?'Bật':'Tắt'} tự động điền. Chủ trang duyệt trước khi áp dụng.`;
    get('entry-preview').textContent=(value.trigger.trim()||'Viết tắt')+' → '+(value.expansion.trim()||'Nghĩa đầy đủ');
    resolved=classifyContribution(catalogue,value,target,action);existingPair=resolved.target;
    blocked=['duplicate','choose'].includes(resolved.action);
    const valid=Boolean(value.trigger.trim()&&value.expansion.trim());
    message.textContent=!valid?'So trùng viết tắt, nghĩa, nhóm và tự động điền; không phân biệt hoa/thường.':resolved.action==='duplicate'?'Toàn bộ thông tin đã giống mục có sẵn. Hãy thay đổi ít nhất một trường để gửi.':resolved.action==='choose'?'Viết tắt này có nhiều nghĩa. Chọn mục cần sửa trong danh sách, hoặc bấm ＋ Nghĩa để bổ sung nghĩa khác.':resolved.action==='edit'?'Thông tin có thay đổi. Sẽ gửi đề xuất chỉnh sửa mục có sẵn để chủ trang duyệt.':'Thông tin mới hoặc khác bộ có sẵn. Có thể gửi để chủ trang kiểm duyệt.';
    get('entry-use-existing').hidden=!existingPair||resolved.action==='edit';
    message.classList.toggle('duplicate',blocked);
    get('save-entry').textContent=resolved.action==='edit'?'Gửi đề xuất chỉnh sửa':'Gửi đề xuất';
    get('save-entry').disabled=sending||blocked||!valid;
    if(!valid||blocked)return;
    checkTimer=setTimeout(async()=>{
      try{
        const result=await store.checkEntry(value);
        if(version!==checkVersion)return;
        if(result.match==='published' || (result.match==='pending'&&!draftReceipt)){
          blocked=true;message.textContent=result.match==='published'?'Toàn bộ thông tin đã giống mục được công bố.':'Đề xuất có toàn bộ thông tin giống nhau đang chờ duyệt.';message.classList.add('duplicate');
        } // Different metadata and selected edits remain eligible.
      }catch{if(version===checkVersion&&!existingPair)message.textContent='Đã kiểm tra danh sách hiện có. Kết nối kiểm tra hàng chờ chưa sẵn sàng; hệ thống sẽ kiểm tra lại khi gửi.';}
      if(version===checkVersion)get('save-entry').disabled=sending||blocked;
    },300);
  }
  function startProposal(row,type){
    resetForm();target=row;action=type;
    get('entry-trigger').value=row.trigger;get('entry-trigger').readOnly=type==='add_meaning';
    get('entry-expansion').value=type==='edit'?row.expansion:'';get('entry-category').value=row.category;
    get('entry-auto').checked=row.auto_replace||false;
    get('entry-many').disabled=true;
    get('proposal-kind').textContent=row.sample?'Đóng góp cho từ trong bộ có sẵn':type==='edit'?'Đề xuất chỉnh nghĩa':'Bổ sung một nghĩa khác';
    get('cancel-edit').hidden=false;updateEditor();get('dictionary-form').scrollIntoView({behavior:'smooth',block:'center'});get('entry-expansion').focus({preventScroll:true});status('Đóng góp chỉ được đưa vào từ điển sau khi chủ trang duyệt.');
  }
  function editAutoFill(row){startProposal(row,'edit');get('entry-auto').focus({preventScroll:true});get('entry-auto').scrollIntoView({behavior:'smooth',block:'center'});}
  function renderDrafts(){
    const host=get('proposal-drafts');host.replaceChildren();
    for(const row of store.drafts){
      const box=document.createElement('div');box.className='dictionary-row';const copy=document.createElement('div');
      const text=document.createElement('p');text.textContent=`Chưa gửi: ${row.trigger} → ${row.expansion}`;copy.append(text);box.append(copy);
      const retry=document.createElement('button');retry.textContent='Gửi lại';retry.onclick=async()=>{try{await store.checkEntry(row);await store.submit(row,{...row});renderDrafts();status('Đã gửi vào hàng chờ duyệt.');}catch(error){status(publicError(error),true);}};
      const discard=document.createElement('button');discard.textContent='Bỏ nháp';discard.onclick=()=>{store.discardDraft(row.receipt);renderDrafts();};box.append(retry,discard);host.append(box);
    }
  }
  function render(){
    const query=get('dictionary-search').value.trim();
    const rows=filterCatalogue(catalogue,{query,category:get('catalogue-category').value,status:get('catalogue-status').value,auto:get('catalogue-auto').value});
    page=Math.max(0,Math.min(page,Math.ceil(rows.length/pageSize)-1));
    get('custom-count').textContent=`${catalogue.length} nghĩa`;
    const approved=catalogue.length;
    get('catalogue-total').textContent=catalogue.length;
    get('catalogue-approved').textContent=approved;
    get('catalogue-source').textContent=mode==='live'?'Đã kết nối từ điển cộng đồng':mode==='cache'?'Đang xem bản đã lưu · chưa tải được bản mới':'Đang xem bộ có sẵn · đã duyệt';
    const host=get('dictionary-list');host.replaceChildren();
    for(const row of rows.slice(page*pageSize,(page+1)*pageSize)){
      const box=document.createElement('tr');box.tabIndex=0;box.className='editable-entry';box.setAttribute('aria-label',`Góp ý ${row.trigger}: ${row.expansion}`);box.onclick=event=>{if(!event.target.closest('button,input,a,select,textarea')&&!window.getSelection()?.toString())startProposal(row,'edit');};box.onkeydown=event=>{if(event.target===box&&['Enter',' '].includes(event.key)){event.preventDefault();startProposal(row,'edit');}};
      for (const value of [row.trigger,row.expansion,names[row.category]||row.category]) {const cell=document.createElement('td');cell.textContent=value;box.append(cell);}
      const stateCell=document.createElement('td'),badge=document.createElement('span');badge.className='catalogue-badge approved';badge.textContent=isBundledEntry(row)?'Đã duyệt · Bộ có sẵn':'Đã duyệt · Cộng đồng';stateCell.append(badge);box.append(stateCell);
      const autoCell=document.createElement('td'),autoButton=document.createElement('button');autoButton.type='button';autoButton.className='auto-fill-state '+(row.auto_replace?'enabled':'disabled');autoButton.textContent=(row.auto_replace?'Bật':'Tắt')+' · Sửa';autoButton.setAttribute('aria-label',`Đề xuất sửa tự động điền ${row.trigger}: ${row.expansion}, hiện ${row.auto_replace?'bật':'tắt'}`);autoButton.onclick=()=>editAutoFill(row);autoCell.append(autoButton);box.append(autoCell);
      const actions=document.createElement('td');actions.className='catalogue-actions';
      const add=document.createElement('button');add.textContent='＋ Nghĩa';add.setAttribute('aria-label',`Bổ sung nghĩa cho ${row.trigger}`);add.onclick=()=>startProposal(row,'add_meaning');
      const edit=document.createElement('button');edit.textContent='Góp ý sửa';edit.setAttribute('aria-label',`Đề xuất sửa nghĩa ${row.trigger}: ${row.expansion}`);edit.onclick=()=>startProposal(row,'edit');actions.append(add,edit);box.append(actions);host.append(box);
    }
    if(!rows.length){const tr=document.createElement('tr'),cell=document.createElement('td');cell.colSpan=6;cell.className='dictionary-empty';cell.textContent='Chưa có kết quả cho bộ lọc này. Bạn có thể gửi đề xuất từ mới.';tr.append(cell);host.append(tr);}
    get('catalogue-page').textContent=`Trang ${page+1}/${Math.max(1,Math.ceil(rows.length/pageSize))} · ${rows.length} nghĩa`;
    get('catalogue-prev').disabled=page===0;get('catalogue-next').disabled=(page+1)*pageSize>=rows.length;
    renderDrafts();updateEditor();
  }
  async function load(){
    get('reload-catalogue').disabled=true;
    try{const approved=await store.loadCatalogue();catalogue=publicCatalogue(baseWords,approved);onChange(keyboardDictionary(baseWords,approved));mode='live';page=0;render();status('Đã tải dữ liệu. Bàn phím dùng bộ có sẵn và dữ liệu đã duyệt; bản duyệt được ưu tiên cho cùng từ viết tắt. Đề xuất đang chờ chưa được sử dụng.');}
    catch(error){const cached=store.cachedCatalogue();if(cached){catalogue=publicCatalogue(baseWords,cached);onChange(keyboardDictionary(baseWords,cached));mode='cache';}render();status(`${publicError(error)} Hiện đang xem ${mode==='sample'?'bộ có sẵn ngoại tuyến':'bản lưu trên máy'}; đóng góp mới không tự công bố.`,true);}
    finally{get('reload-catalogue').disabled=false;}
  }
  function route(event){
    const dictionary=location.hash==='#dictionary';
    get('playground').hidden=dictionary;get('dictionary-page').hidden=!dictionary;
    for(const name of ['playground','dictionary']){const active=(name==='dictionary')===dictionary;get('tab-'+name).setAttribute('aria-selected',active);get('tab-'+name).tabIndex=active?0:-1;}
    if(event)window.scrollTo(0,0);
  }
  window.addEventListener('hashchange',route);
  const tabs=[get('tab-playground'),get('tab-dictionary')];
  for(const tab of tabs)tab.onkeydown=event=>{
    if(!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return;
    event.preventDefault();const next=event.key==='Home'?tabs[0]:event.key==='End'?tabs[1]:tabs.find(item=>item!==tab);next.click();next.focus();
  };
  get('new-proposal').onclick=()=>{resetForm(true);get('dictionary-form').scrollIntoView({behavior:'smooth',block:'center'});get('entry-trigger').focus({preventScroll:true});};
  get('cancel-edit').onclick=()=>resetForm(true);
  for(const id of ['catalogue-category','catalogue-status','catalogue-auto'])get(id).onchange=()=>{page=0;render();};
  get('dictionary-search').oninput=()=>{page=0;render();};get('catalogue-prev').onclick=()=>{page--;render();};get('catalogue-next').onclick=()=>{page++;render();};get('reload-catalogue').onclick=load;
  get('dictionary-form').onsubmit=async event=>{
    event.preventDefault();if(sending||blocked)return;sending=true;get('dictionary-form').inert=true;get('dictionary-form').setAttribute('aria-busy','true');get('new-proposal').disabled=true;get('save-entry').disabled=true;
    try{
      if(entryMode==='many'){
        const rows=batchRows().filter(row=>!row.error);let ok=0,failed=0;if(!rows.length)return;await store.checkEntry(rows[0].value);
        for(const [i,row] of rows.entries()){
          get('entry-save-state').textContent=`Đang gửi ${i+1}/${rows.length}…`;
          try{await store.submit(row.value,{...row.context,explanation:get('entry-explanation').value,name:get('contributor-name').value});ok++;}catch{failed++;}
        }
        resetForm();try{localStorage.removeItem(composerKey);}catch{}
        status(`Đã gửi ${ok} đề xuất vào hàng chờ. ${failed?failed+' mục chưa gửi được; xem bản nháp bên dưới.':'Chủ trang sẽ kiểm tra trước khi công bố.'}`,Boolean(failed));return;
      }
      updateEditor();if(blocked)return;await store.checkEntry(editorInput());
      draftReceipt ||= crypto.randomUUID();
      const result=await store.submit({trigger:get('entry-trigger').value,expansion:get('entry-expansion').value,category:get('entry-category').value,auto_replace:get('entry-auto').checked},
        {action:resolved.action,target:resolved.target,receipt:draftReceipt,explanation:get('entry-explanation').value,name:get('contributor-name').value});
      resetForm();try{localStorage.removeItem(composerKey);}catch{}status(`Đã nhận đề xuất ${result.id.slice(0,8)}. Chủ trang sẽ kiểm tra trước khi công bố.`);
    }catch(error){const saved=store.drafts.some(row=>row.receipt===draftReceipt);status(`${publicError(error)} ${saved?'Đề xuất chưa được xác nhận gửi; bản nháp đã được giữ trên máy.':'Hãy kiểm tra lại nội dung trước khi gửi.'}`,true);}
    finally{sending=false;get('dictionary-form').inert=false;get('dictionary-form').removeAttribute('aria-busy');get('new-proposal').disabled=false;updateEditor();renderDrafts();}
  };
  get('dictionary-form').addEventListener('input',()=>{
    draftReceipt=null;updateEditor();
    if(!target)try{localStorage.setItem(composerKey,JSON.stringify({...editorInput(),explanation:get('entry-explanation').value,lines:get('entry-lines').value,mode:entryMode}));get('entry-save-state').textContent='Đã giữ nội dung trên thiết bị này.';}catch{}
  });
  get('entry-single').onclick=()=>setEntryMode('single');get('entry-many').onclick=()=>setEntryMode('many');
  get('entry-use-existing').onclick=()=>{if(existingPair)startProposal(existingPair,'edit');};
  get('entry-match-all').onclick=()=>{
    get('dictionary-search').value=get('entry-trigger').value.trim();get('catalogue-category').value='';get('catalogue-status').value='';get('catalogue-auto').value='';page=0;render();get('dictionary-search').scrollIntoView({behavior:'smooth',block:'center'});get('dictionary-search').focus({preventScroll:true});
  };
  resetForm();
  try{const saved=JSON.parse(localStorage.getItem(composerKey));if(saved){get('entry-trigger').value=saved.trigger||'';get('entry-expansion').value=saved.expansion||'';get('entry-category').value=saved.category||'chat';get('entry-auto').checked=Boolean(saved.auto_replace);get('entry-explanation').value=saved.explanation||'';get('entry-lines').value=saved.lines||'';setEntryMode(saved.mode==='many'?'many':'single');get('entry-save-state').textContent='Đã khôi phục nội dung bạn đang nhập.';}}catch{}
  render();route();onChange(keyboardDictionary(baseWords));load();return store;
}
