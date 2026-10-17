// Produce a double-clickable local demo; no server or package installation needed.
import fs from 'node:fs';
const base = new URL('./dist/', import.meta.url);
const read = name => fs.readFileSync(new URL(name, base), 'utf8').replaceAll('\r\n','\n');
let html = read('index.html');
const css = read('style.css');
const engine = read('engine.mjs').replace(/^export /gm, '');
const stripModule = script => script.replace(/^import .*\n/gm, '').replace(/^export /gm, '');
const cloud = stripModule(read('config.mjs')) + '\n' + stripModule(read('dictionary-store.mjs')) + '\n' + stripModule(read('community-store.mjs')) + '\n' + stripModule(read('community-ui.mjs'));
const words = JSON.stringify(JSON.parse(read('words.json'))).replaceAll('<', '\\u003c');
const app = read('app.js').replace(/^import .*\n/gm, '').replace("await (await fetch('./words.json')).json()", () => words);
// Callback replacements preserve literal JS sequences such as $' and $&.
// A replacement string would interpolate HTML suffixes into the script.
html = html.replace('<link rel="stylesheet" href="style.css">', () => '<style>' + css + '</style>');
html = html.replace('<link rel="stylesheet" href="dictionary.css">', () => '<style>' + read('dictionary.css') + '</style>');
html = html.replace('<link rel="stylesheet" href="community.css">', () => '<style>' + read('community.css') + '</style>');
const inlineScript = (engine + '\n' + stripModule(read('editor-model.mjs')) + '\n' + cloud + '\n' + app).replace(/<\/script/gi, '<\\/script');
html = html.replace('<script type="module" src="app.js"></script>', () => '<script type="module">\n' + inlineScript + '\n</script>');
fs.writeFileSync(new URL('./preview.html', import.meta.url), html);
const migration=fs.readFileSync(new URL('../supabase/migrations/20261017_community_moderation.sql',import.meta.url),'utf8');
const seeds=fs.readFileSync(new URL('../supabase/seeds/initial_dictionary.sql',import.meta.url),'utf8');
fs.writeFileSync(new URL('./dist/supabase-setup.sql',import.meta.url),migration+'\n'+seeds);
console.log('Created web/preview.html');
