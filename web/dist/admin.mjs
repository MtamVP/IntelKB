import {CommunityStore} from './community-store.mjs';
import {validateEntry} from './dictionary-store.mjs';
const adminGet=id=>document.getElementById(id),adminStore=new CommunityStore();
let adminAllowed=false,adminPage=0,adminRows=[],adminSelected=null,adminKind='proposals';
function adminStatus(text,error=false){adminGet('admin-status').textContent=text;adminGet('admin-status').classList.toggle('error',error);}
function hideAdmin(){adminAllowed=false;adminRows=[];adminSelected=null;adminGet('queue-list').replaceChildren();adminGet('review-form').hidden=true;adminGet('admin-panel').hidden=true;adminGet('admin-login').hidden=false;}
async function authorizeAdmin(){
  hideAdmin();
  if(!adminStore.session)return;
  try{
    if(!await adminStore.isAdmin())throw new Error('Tài khoản này chưa có quyền quản trị. Cấp UUID của tài khoản trong bảng intelkb_admins bằng SQL Editor.');
    adminAllowed=true;adminGet('admin-login').hidden=true;adminGet('admin-panel').hidden=false;await loadAdminQueue();
  }catch(error){hideAdmin();adminStatus(error.message,true);}
}
async function loadAdminQueue(){
  if(!adminAllowed)return;
  adminGet('queue-reload').disabled=true;adminGet('review-form').hidden=true;adminSelected=null;
  try{
    adminKind=adminGet('queue-kind').value;
    const chosen=adminGet('queue-filter').value;
    const state=adminKind==='seeds'?({pending:'draft',accepted:'approved',rejected:'rejected'}[chosen]):chosen;
    adminRows=await adminStore.adminRows(adminKind,state,adminPage*50);
    const host=adminGet('queue-list');host.replaceChildren();
    for(const row of adminRows.slice(0,50)){
      const card=document.createElement('article');card.className='queue-card';
      const button=document.createElement('button');button.textContent=`${row.trigger} → ${row.expansion}`;button.onclick=()=>openAdminReview(row);
      const meta=document.createElement('small');meta.textContent=`${row.action||'Bộ khởi tạo'} · ${row.status} · ${new Date(row.created_at).toLocaleString('vi-VN')}`;
      card.append(button,document.createElement('br'),meta);host.append(card);
    }
    if(!adminRows.length){const p=document.createElement('p');p.className='admin-subtitle';p.textContent='Không có mục nào ở trạng thái này.';host.append(p);}
    adminGet('queue-description').textContent=adminKind==='seeds'?'Các nghĩa khởi tạo cũng phải được bạn duyệt; không tự công bố toàn bộ dữ liệu.':'Người dùng gửi không cần đăng nhập. Chỉ các nghĩa được bạn Accept mới xuất hiện trong từ điển chung.';
    adminGet('queue-prev').disabled=adminPage===0;adminGet('queue-next').disabled=adminRows.length<=50;adminGet('queue-page').textContent=`Trang ${adminPage+1}`;
    adminStatus('Đã tải hàng chờ.');
  }catch(error){adminStatus(error.message,true);}
  finally{adminGet('queue-reload').disabled=false;}
}
async function openAdminReview(row){
  adminSelected=row;
  const lines=[`${row.trigger} → ${row.expansion}`,`Loại: ${row.action||'Bộ khởi tạo'}`];
  if(row.explanation)lines.push(`Giải thích: ${row.explanation}`);if(row.contributor_name)lines.push(`Người góp ý: ${row.contributor_name}`);if(row.moderator_note)lines.push(`Ghi chú: ${row.moderator_note}`);
  if(row.target_id){try{const target=await adminStore.target(row.target_id);if(adminSelected!==row)return;lines.push(target?`Nghĩa hiện tại: ${target.trigger} → ${target.expansion} (v${target.revision}; đề xuất dựa trên v${row.base_revision})`:'Mục gốc không còn tồn tại.');}catch(error){adminStatus(error.message,true);return;}}
  adminGet('review-original').textContent=lines.join('\n');adminGet('review-expansion').value=row.expansion;adminGet('review-category').value=row.category;adminGet('review-auto').checked=row.auto_replace;adminGet('review-note').value='';
  const pending=['pending','draft'].includes(row.status);adminGet('accept-proposal').hidden=!pending;adminGet('reject-proposal').hidden=!pending;
  adminGet('review-form').hidden=false;adminGet('review-form').scrollIntoView({behavior:'smooth',block:'center'});
}
async function decideAdmin(decision){
  if(!adminSelected || !adminAllowed)return;
  const row=adminSelected,kind=adminKind;
  const buttons=[...adminGet('review-form').querySelectorAll('button')];buttons.forEach(b=>b.disabled=true);
  try{
    const override=decision==='accept'?validateEntry({trigger:row.trigger,expansion:adminGet('review-expansion').value,category:adminGet('review-category').value,auto_replace:adminGet('review-auto').checked}):null;
    await adminStore.review(row,kind,decision,adminGet('review-note').value,override);
    await loadAdminQueue();adminStatus(decision==='accept'?'Đã chấp nhận và công bố. Người dùng tải lại từ điển sẽ nhận nghĩa mới.':'Đã từ chối. Từ điển chung không thay đổi.');
  }catch(error){adminStatus(error.message,true);}
  finally{buttons.forEach(b=>b.disabled=false);}
}
adminGet('admin-login').onsubmit=async event=>{event.preventDefault();adminGet('login-button').disabled=true;try{await adminStore.signIn(adminGet('admin-email').value.trim(),adminGet('admin-password').value);adminGet('admin-password').value='';await authorizeAdmin();}catch(error){adminStatus(error.message,true);}finally{adminGet('login-button').disabled=false;}};
adminGet('admin-logout').onclick=async()=>{hideAdmin();await adminStore.signOut();adminStatus('Đã đăng xuất.');};
adminGet('queue-kind').onchange=adminGet('queue-filter').onchange=()=>{adminPage=0;loadAdminQueue();};adminGet('queue-reload').onclick=loadAdminQueue;
adminGet('queue-prev').onclick=()=>{adminPage--;loadAdminQueue();};adminGet('queue-next').onclick=()=>{adminPage++;loadAdminQueue();};
adminGet('review-form').onsubmit=e=>{e.preventDefault();decideAdmin('accept');};adminGet('reject-proposal').onclick=()=>decideAdmin('reject');adminGet('cancel-review').onclick=()=>{adminSelected=null;adminGet('review-form').hidden=true;};
authorizeAdmin();
