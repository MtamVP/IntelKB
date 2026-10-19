import {TEXT_TOOLS,applyTextTool,textStats,QUICK_SYMBOLS} from './text-tools.mjs';
import {PersonalLibrary} from './personal-library.mjs';

export function mountToolbox(api){
 const byId=id=>document.getElementById(id),dialog=byId('keyboard-tools'),library=new PersonalLibrary();
 const fold=text=>String(text).normalize('NFD').replace(/\p{M}/gu,'').replace(/[đĐ]/g,'d').toLocaleLowerCase('vi');
 let anchor=null,tab='text',chosen=null,editing=null,removed=null;
 const node=(tag,text,cls='')=>{const el=document.createElement(tag);el.textContent=text;if(cls)el.className=cls;return el;};
 function message(text,error=false){byId('tool-status').textContent=text;byId('tool-status').classList.toggle('error',error);}
 function currentScope(){return anchor.start!==anchor.end?{start:anchor.start,end:anchor.end}:{start:0,end:anchor.text.length};}
 function sourceText(){const range=currentScope();return anchor.text.slice(range.start,range.end);}
 function ensureCurrent(){if(api.read().text!==anchor.text)throw new Error('Nội dung ô nhập đã đổi. Hãy đóng và mở lại Công cụ trước khi chèn.');}
 function insertLiteral(text){try{ensureCurrent();api.replace(anchor.start,anchor.end,text);dialog.close();api.notify('Đã chèn nguyên văn. Có thể hoàn tác.');}catch(error){message(error.message,true);}}
 function download(value,name,type){const url=URL.createObjectURL(new Blob([value],{type})),link=document.createElement('a');link.href=url;link.download=name;link.click();setTimeout(()=>URL.revokeObjectURL(url),1000);}
 function render(){
  const query=fold(byId('tool-search').value.trim());
  const host=byId('tool-command-list');host.replaceChildren();
  for(const tool of TEXT_TOOLS.filter(tool=>fold(tool.label+' '+tool.description).includes(query))){
   const button=node('button','');button.type='button';button.className='tool-command';button.setAttribute('aria-pressed',String(chosen===tool.id));button.append(node('strong',tool.label),node('small',tool.description));
   button.onclick=()=>{chosen=tool.id;byId('tool-preview').value=applyTextTool(chosen,sourceText());byId('tool-preview-label').textContent='Xem trước · '+tool.label;byId('tool-apply').disabled=byId('tool-preview').value===sourceText();for(const other of host.querySelectorAll('button'))other.setAttribute('aria-pressed',String(other===button));};host.append(button);
  }
  if(!host.children.length)host.append(node('p','Không tìm thấy công cụ phù hợp.','tool-empty'));
  const kind=byId('tool-library-kind').value;
  const found=library.rows.filter(row=>(!kind||row.kind===kind)&&fold(row.title+' '+row.text).includes(query)).sort((a,b)=>Number(b.pinned)-Number(a.pinned)||b.updatedAt.localeCompare(a.updatedAt));
  const saved=byId('tool-library-list');saved.replaceChildren();byId('tool-library-count').textContent=`${found.length} mục · ${library.rows.length}/300 đang lưu trên thiết bị`;
  for(const row of found.slice(0,60)){
   const item=node('article','');item.className='tool-saved';item.append(node('strong',(row.pinned?'★ ':'')+row.title),node('small',row.kind==='clip'?'Đoạn đã lưu':'Câu thường dùng'),node('p',row.text.slice(0,160)+(row.text.length>160?'…':'')));
   const actions=node('div','');
   for(const [label,action] of [['Chèn',()=>insertLiteral(row.text)],['Sửa',()=>{editing=row.id;byId('tool-title').value=row.title;byId('tool-content').value=row.text;byId('tool-item-kind').value=row.kind;byId('tool-save-item').textContent='Lưu bản sửa';byId('tool-cancel-edit').hidden=false;byId('tool-title').focus();}],
    [row.pinned?'Bỏ ghim':'Ghim',()=>{library.save({...row,pinned:!row.pinned},row.id);render();}],['Bỏ',()=>{removed=library.remove(row.id);if(editing===row.id)resetForm();byId('tool-undo-delete').hidden=!removed;message('Đã bỏ mục lưu. Có thể hoàn tác ở phía dưới.');render();}]]){
    const button=node('button',label);button.type='button';button.onclick=()=>{try{action();}catch(error){message(error.message,true);}};actions.append(button);
   }
   item.append(actions);saved.append(item);
  }
  if(!found.length)saved.append(node('p',library.rows.length?'Không có mục khớp tìm kiếm.':'Chưa có mục nào. Chỉ những nội dung bạn bấm lưu mới xuất hiện ở đây.','tool-empty'));
  if(found.length>60)saved.append(node('p','Đang hiện 60 mục đầu. Gõ tìm kiếm để thu hẹp danh sách.','tool-empty'));
  const symbols=byId('tool-symbol-list');symbols.replaceChildren();
  for(const symbol of QUICK_SYMBOLS.filter(symbol=>!query||fold(symbol).includes(query))){const button=node('button',symbol);button.type='button';button.setAttribute('aria-label','Chèn '+symbol);button.onclick=()=>insertLiteral(symbol);symbols.append(button);}
  if(!symbols.children.length)symbols.append(node('p','Không có ký hiệu khớp. Xóa tìm kiếm để xem tất cả.','tool-empty'));
 }
 function setTab(value){tab=value;for(const name of ['text','library','symbols']){const active=name===tab;byId('tool-tab-'+name).setAttribute('aria-selected',String(active));byId('tool-tab-'+name).tabIndex=active?0:-1;byId('tool-panel-'+name).hidden=!active;}render();}
 function resetForm(){editing=null;byId('tool-library-form').reset();byId('tool-save-item').textContent='Lưu trên thiết bị';byId('tool-cancel-edit').hidden=true;}
 function open(){
  if(dialog.open)return;try{anchor=api.read();}catch(error){api.notify(error.message);return;}
  chosen=null;byId('tool-search').value='';byId('tool-preview').value=sourceText();byId('tool-preview-label').textContent='Nội dung ban đầu';byId('tool-apply').disabled=true;
  const stats=textStats(sourceText());byId('tool-scope').textContent=(anchor.start!==anchor.end?'Áp dụng cho phần đang chọn':'Chưa chọn riêng: áp dụng cho cả ô nhập')+` · ${stats.characters} ký tự · ${stats.words} từ · ${stats.lines} dòng`;
  message(library.error||'Xem trước rồi bấm Áp dụng. Mọi thay đổi trong ô nhập đều có thể hoàn tác.',Boolean(library.error));setTab('text');dialog.showModal();byId('tool-search').focus();dialog.scrollTop=0;
 }
 byId('open-tools').onclick=open;byId('tool-close').onclick=()=>dialog.close();
 dialog.addEventListener('close',()=>api.focus());
 byId('tool-search').oninput=render;byId('tool-library-kind').onchange=render;
 for(const name of ['text','library','symbols']){
  const button=byId('tool-tab-'+name);button.onclick=()=>setTab(name);
  button.onkeydown=event=>{if(!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return;event.preventDefault();const names=['text','library','symbols'],at=names.indexOf(name),next=event.key==='Home'?names[0]:event.key==='End'?names[2]:names[(at+(event.key==='ArrowRight'?1:2))%3];setTab(next);byId('tool-tab-'+next).focus();};
 }
 byId('tool-apply').onclick=()=>{try{if(!chosen)return;ensureCurrent();const range=currentScope();api.replace(range.start,range.end,byId('tool-preview').value,{selectResult:anchor.start!==anchor.end});dialog.close();api.notify('Đã áp dụng '+TEXT_TOOLS.find(tool=>tool.id===chosen).label+'. Có thể hoàn tác.');}catch(error){message(error.message,true);}};
 byId('tool-save-selection').onclick=()=>{resetForm();const text=sourceText();byId('tool-content').value=text;byId('tool-title').value=text.trim().split(/\r?\n/)[0].slice(0,80);byId('tool-item-kind').value='clip';byId('tool-title').focus();message('Kiểm tra tên và nội dung rồi bấm Lưu trên thiết bị.');};
 byId('tool-library-form').onsubmit=event=>{event.preventDefault();try{const old=library.rows.find(row=>row.id===editing);library.save({title:byId('tool-title').value,text:byId('tool-content').value,kind:byId('tool-item-kind').value,pinned:old?.pinned||false},editing);resetForm();render();message('Đã lưu trên thiết bị này. Không gửi lên Supabase.');}catch(error){message(error.message,true);}};
 byId('tool-cancel-edit').onclick=resetForm;
 byId('tool-undo-delete').onclick=()=>{try{if(!removed)return;library.save(removed);removed=null;byId('tool-undo-delete').hidden=true;render();message('Đã khôi phục mục vừa bỏ.');}catch(error){message(error.message,true);}};
 byId('tool-export').onclick=()=>{try{download(JSON.stringify(library.export(),null,2),'intelkb-ca-nhan.json','application/json;charset=utf-8');message('Đã xuất bộ lưu cá nhân. File này có thể chứa nội dung riêng của bạn.');}catch(error){message(error.message,true);}};
 byId('tool-import').onchange=async event=>{const file=event.target.files[0];if(!file)return;try{if(file.size>10*1024*1024)throw new Error('File tối đa 10 MB.');const result=library.import(JSON.parse(await file.text()));render();message(`Đã thêm ${result.added} mục, bỏ qua ${result.skipped} mục trùng. Các mục cũ được giữ nguyên.`);}catch(error){message(error instanceof SyntaxError?'File JSON không hợp lệ. Chưa thay đổi dữ liệu.':error.message,true);}finally{event.target.value='';}};
 byId('tool-download-text').onclick=()=>{download(sourceText(),'intelkb-van-ban.txt','text/plain;charset=utf-8');message('Đã tải phần văn bản đang áp dụng.');};
 return {open};
}
