import { CommunityStore } from './community-store.mjs';

export function mountDictionary(baseWords,onChange) {
  const get=id=>document.getElementById(id), store=new CommunityStore();
  let catalogue=baseWords.map((row,i)=>({...row,id:`sample-${i}`,sample:true})), mode='sample',page=0,target=null,action='new',draftReceipt=null;
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
    get('cancel-edit').hidden=false;get('entry-expansion').focus();status('Đóng góp chỉ được đưa vào từ điển sau khi chủ trang duyệt.');
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
    const query=get('dictionary-search').value.trim().toLocaleLowerCase('vi');
    const rows=catalogue.filter(row=>`${row.trigger} ${row.expansion}`.toLocaleLowerCase('vi').includes(query));
    page=Math.max(0,Math.min(page,Math.ceil(rows.length/pageSize)-1));
    get('custom-count').textContent=`${catalogue.length} nghĩa`;
    get('catalogue-source').textContent=mode==='live'?'Từ điển chung · chỉ các nghĩa đã duyệt':mode==='cache'?'Bản đã duyệt lưu trên máy · chưa tải được bản mới':'Bộ mẫu ngoại tuyến · chưa phải danh sách đã duyệt';
    const host=get('dictionary-list');host.replaceChildren();
    for(const row of rows.slice(page*pageSize,(page+1)*pageSize)){
      const box=document.createElement('div');box.className='dictionary-row';
      const copy=document.createElement('div'),trigger=document.createElement('strong'),meaning=document.createElement('p'),meta=document.createElement('small');
      trigger.textContent=row.trigger;meaning.textContent=row.expansion;meta.textContent=`${names[row.category]||row.category} · ${row.sample?'Mẫu chưa kiểm duyệt':'Đã duyệt'}`;
      copy.append(trigger,meaning,meta);box.append(copy);
      const add=document.createElement('button');add.textContent='＋ Nghĩa';add.setAttribute('aria-label',`Bổ sung nghĩa cho ${row.trigger}`);add.onclick=()=>startProposal(row,'add_meaning');
      const edit=document.createElement('button');edit.textContent='Góp ý sửa';edit.setAttribute('aria-label',`Đề xuất sửa nghĩa ${row.trigger}: ${row.expansion}`);edit.onclick=()=>startProposal(row,'edit');box.append(add,edit);host.append(box);
    }
    if(!rows.length){const p=document.createElement('p');p.className='dictionary-empty';p.textContent=query?'Không có kết quả. Bạn có thể đề xuất từ mới ở trên.':'Chưa có nghĩa nào được công bố. Hãy gửi từ đầu tiên để chủ trang duyệt.';host.append(p);}
    get('catalogue-page').textContent=`Trang ${page+1}/${Math.max(1,Math.ceil(rows.length/pageSize))} · ${rows.length} nghĩa`;
    get('catalogue-prev').disabled=page===0;get('catalogue-next').disabled=(page+1)*pageSize>=rows.length;
    onChange(catalogue);renderDrafts();
  }
  async function load(){
    get('reload-catalogue').disabled=true;
    try{catalogue=await store.loadCatalogue();mode='live';page=0;render();status('Đã tải danh sách được chủ trang duyệt.');}
    catch(error){const cached=store.cachedCatalogue();if(cached){catalogue=cached;mode='cache';}render();status(`${publicError(error)} Hiện đang xem ${mode==='sample'?'bộ mẫu ngoại tuyến':'bản lưu trên máy'}; đóng góp mới không tự công bố.`,true);}
    finally{get('reload-catalogue').disabled=false;}
  }
  get('open-dictionary').onclick=()=>{get('dictionary-dialog').showModal();render();};
  get('close-dictionary').onclick=()=>get('dictionary-dialog').close();get('cancel-edit').onclick=resetForm;
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
  resetForm();render();load();return store;
}
