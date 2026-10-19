import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

test('public and admin scripts only reference controls present in their HTML',()=>{
 for(const [htmlName,scripts] of [['index.html',['app.js','community-ui.mjs','toolbox-ui.mjs']],['workbench-ink-7c91.html',['admin.mjs']]]){
  const html=fs.readFileSync(new URL('../dist/'+htmlName,import.meta.url),'utf8');
  const matches=[...html.matchAll(/\bid="([^"]+)"/g)].map(match=>match[1]),ids=new Set(matches);
  assert.equal(matches.length,ids.size,`${htmlName} contains duplicate IDs`);
  for(const name of scripts){
   const source=fs.readFileSync(new URL('../dist/'+name,import.meta.url),'utf8');
   for(const match of source.matchAll(/(?:\bel|\bget|\bbyId)\('([^']+)'\)|\$\('#([^']+)'\)/g)){
    const id=match[1]||match[2];assert.ok(ids.has(id),`${name} references missing control ${id}`);
   }
  }
  for(const match of html.matchAll(/(?:src|href)="([^"#]+\.(?:css|mjs|js|sql))"/g)){
   if(!/^https?:/.test(match[1]))assert.ok(fs.existsSync(new URL('../dist/'+match[1],import.meta.url)),`Missing asset ${match[1]}`);
  }
 }
});
