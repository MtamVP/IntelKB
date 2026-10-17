import { CommunityStore } from './community-store.mjs';
import { publicCatalogue, filterCatalogue, keyboardDictionary } from './catalogue.mjs';

export function mountDictionary(baseWords,onChange) {
  const get=id=>document.getElementById(id), store=new CommunityStore();
  let catalogue=publicCatalogue(baseWords,[]), mode='sample',page=0,target=null,action='new',draftReceipt=null;
  const pageSize=40,names={chat:'Nhắn tin',profanity:'Từ tục',euphemism:'Nói nhẹ',english:'Tiếng Anh',game:'Game'};
  function status(text,error=false){get('dictionary-status').textContent=text;get('dictionary-status').classList.toggle('error',error);}
  function publicError(error){
    if(/Từ viết tắt|Nghĩa đầy đủ|Hãy chọn nhóm|cần khác|Ghi chú tối đa/.test(error.message))return error.message;
    if(error.message.includes('database cộng đồng'))return 'Từ điển cộng đồng chưa được kích hoạt.';
    if(error.message.includes('identical proposal')||error.message.includes('intelkb_pending_proposal_unique'))return 'Đã có một đóng góp giống như vậy đang chờ duyệt.';
    if(error.message.includes('Entry changed')||error.message.includes('Target no longer'))return 'Mục từ đã thay đổi. Tải lại danh sách và góp ý trên bản mới nhé.';
    return 'Chưa kết nối được hệ thống đóng góp. Hãy thử lại sau.';
  }
  function resetForm(){get('dictionary-form').reset();target=null;action='new';draftReceipt=null;get('entry-trigger').readOnly=false;get('proposal-kind').textContent='Đề xuất từ mới';get('cancel-edit').hidden=true;get('save-entry').textContent='Gửi đề xuất';}
  function startProposal(row,type){
    resetForm();target=row.sample?null:row;action=row.sample?'new':type;
    get('entry-trigger').value=row.trigger;get('entry-trigger').readOnly=Boolean(target);
    get('entry-expansion').value=type==='edit'?row.expansion:'';get('entry-category').value=row.category;
    get('entry-auto').checked=row.auto_replace||false;
    get('proposal-kind').textContent=row.sample?'Đóng góp cho từ trong bộ mẫu':type==='edit'?'Đề xuất chỉnh nghĩa':'Bổ sung một nghĩa khác';
    get('cancel-edit').hidden=false;get('dictionary-form').scrollIntoView({behavior:'smooth',block:'center'});get('entry-expansion').focus({preventScroll:true});status('Đóng góp chỉ được đưa vào từ điển sau khi chủ trang duyệt.');
  }
  function renderDrafts(){
    const host=get('proposal-drafts');host.replaceChildren();
    for(const row of store.drafts){
      const box=document.createElement('div');box.className='dictionary-row';const copy=document.createElement('div');
      const text=document.createElement('p');text.textContent=`Chưa gửi: ${row.trigger} → ${row.expansion}`;copy.append(text);box.append(copy);
      const retry=document.createElement('button');retry.textContent='Gửi lại';retry.onclick=async()=>{try{await store.submit(row,{...row});renderDrafts();status('Đã gửi vào hàng chờ duyệt.');}catch(error){status(publicError(error),true);}};
      const discard=document.createElement('button');discard.textContent='Bỏ nháp';discard.onclick=()=>{store.discardDraft(row.receipt);renderDrafts();};box.append(retry,discard);host.append(box);
    }
  }
  function render(){
    const query=get('dictionary-search').value.trim();
    const rows=filterCatalogue(catalogue,{query,category:get('catalogue-category').value,status:get('catalogue-status').value});
    page=Math.max(0,Math.min(page,Math.ceil(rows.length/pageSize)-1));
    get('custom-count').textContent=`${catalogue.length} nghĩa`;
    const approved=catalogue.filter(row=>!row.sample).length;
    get('catalogue-total').textContent=catalogue.length;
    get('catalogue-approved').textContent=approved;
    get('catalogue-source').textContent=mode==='live'?'Đã kết nối từ điển cộng đồng':mode==='cache'?'Đang xem bản đã lưu · chưa tải được bản mới':'Đang xem bộ mẫu tham khảo';
    const host=get('dictionary-list');host.replaceChildren();
    for(const row of rows.slice(page*pageSize,(page+1)*pageSize)){
      const box=document.createElement('tr');
      for (const value of [row.trigger,row.expansion,names[row.category]||row.category]) {const cell=document.createElement('td');cell.textContent=value;box.append(cell);}
      const stateCell=document.createElement('td'),badge=document.createElement('span');badge.className=row.sample?'catalogue-badge sample':'catalogue-badge approved';badge.textContent=row.sample?'Tham khảo':'Đã duyệt';stateCell.append(badge);box.append(stateCell);
      const actions=document.createElement('td');actions.className='catalogue-actions';
      const add=document.createElement('button');add.textContent='＋ Nghĩa';add.setAttribute('aria-label',`Bổ sung nghĩa cho ${row.trigger}`);add.onclick=()=>startProposal(row,'add_meaning');
      const edit=document.createElement('button');edit.textContent='Góp ý sửa';edit.setAttribute('aria-label',`Đề xuất sửa nghĩa ${row.trigger}: ${row.expansion}`);edit.onclick=()=>startProposal(row,'edit');actions.append(add,edit);box.append(actions);host.append(box);
    }
    if(!rows.length){const tr=document.createElement('tr'),cell=document.createElement('td');cell.colSpan=5;cell.className='dictionary-empty';cell.textContent='Chưa có kết quả cho bộ lọc này. Bạn có thể gửi đề xuất từ mới.';tr.append(cell);host.append(tr);}
    get('catalogue-page').textContent=`Trang ${page+1}/${Math.max(1,Math.ceil(rows.length/pageSize))} · ${rows.length} nghĩa`;
    get('catalogue-prev').disabled=page===0;get('catalogue-next').disabled=(page+1)*pageSize>=rows.length;
    renderDrafts();
  }
  async function load(){
    get('reload-catalogue').disabled=true;
    try{const approved=await store.loadCatalogue();catalogue=publicCatalogue(baseWords,approved);onChange(keyboardDictionary(baseWords,approved));mode='live';page=0;render();status('Đã tải dữ liệu. Bàn phím dùng bộ mẫu thử và dữ liệu đã duyệt; bản duyệt được ưu tiên cho cùng từ viết tắt. Đề xuất đang chờ chưa được sử dụng.');}
    catch(error){const cached=store.cachedCatalogue();if(cached){catalogue=publicCatalogue(baseWords,cached);onChange(keyboardDictionary(baseWords,cached));mode='cache';}render();status(`${publicError(error)} Hiện đang xem ${mode==='sample'?'bộ mẫu ngoại tuyến':'bản lưu trên máy'}; đóng góp mới không tự công bố.`,true);}
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
  get('new-proposal').onclick=()=>{resetForm();get('dictionary-form').scrollIntoView({behavior:'smooth',block:'center'});get('entry-trigger').focus({preventScroll:true});};
  get('cancel-edit').onclick=resetForm;
  for(const id of ['catalogue-category','catalogue-status'])get(id).onchange=()=>{page=0;render();};
  get('dictionary-search').oninput=()=>{page=0;render();};get('catalogue-prev').onclick=()=>{page--;render();};get('catalogue-next').onclick=()=>{page++;render();};get('reload-catalogue').onclick=load;
  get('dictionary-form').onsubmit=async event=>{
    event.preventDefault();get('save-entry').disabled=true;
    try{
      draftReceipt ||= crypto.randomUUID();
      const result=await store.submit({trigger:get('entry-trigger').value,expansion:get('entry-expansion').value,category:get('entry-category').value,auto_replace:get('entry-auto').checked},
        {action,target,receipt:draftReceipt,explanation:get('entry-explanation').value,name:get('contributor-name').value});
      resetForm();status(`Đã nhận đề xuất ${result.id.slice(0,8)}. Chủ trang sẽ kiểm tra trước khi công bố.`);
    }catch(error){const saved=store.drafts.some(row=>row.receipt===draftReceipt);status(`${publicError(error)} ${saved?'Đề xuất chưa được xác nhận gửi; bản nháp đã được giữ trên máy.':'Hãy kiểm tra lại nội dung trước khi gửi.'}`,true);}
    finally{get('save-entry').disabled=false;renderDrafts();}
  };
  get('dictionary-form').addEventListener('input',()=>{draftReceipt=null;});
  resetForm();render();route();onChange(keyboardDictionary(baseWords));load();return store;
}
