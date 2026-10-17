"""Seed the initial corpus as DRAFT, never as moderator-approved content."""
import json
import pathlib
import uuid

root=pathlib.Path(__file__).resolve().parents[1]
rows=json.loads((root/'web/dist/words.json').read_text(encoding='utf-8'))
quote=lambda text: "'"+text.replace("'","''")+"'"
lines=['-- Initial editorial candidates: owner must review each before public use.', 'begin;']
for row in rows:
    identity=str(uuid.uuid5(uuid.NAMESPACE_URL,'intelkb:'+row['trigger']+'\0'+row['expansion']))
    fields=[identity,row['trigger'],row['expansion'],row['category']]
    lines.append('insert into public.intelkb_dictionary(id,trigger,expansion,category,status,source) values('+','.join(map(quote,fields))+",'draft','bootstrap') on conflict(id) do nothing;")
lines.append('commit;')
target=root/'supabase/seeds/initial_dictionary.sql'
target.parent.mkdir(parents=True,exist_ok=True)
target.write_text('\n'.join(lines)+'\n',encoding='utf-8')
print(f'Prepared {len(rows)} DRAFT seed entries.')
