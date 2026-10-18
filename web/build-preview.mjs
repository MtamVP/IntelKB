// Produce a double-clickable local demo; no server or package installation needed.
import fs from 'node:fs';
import {referenceApprovalSql} from './reference-approval.mjs';
const base = new URL('./dist/', import.meta.url);
const read = name => fs.readFileSync(new URL(name, base), 'utf8').replaceAll('\r\n','\n');
let html = read('index.html');
// Keep GitHub Pages entry points in sync with the distributable pages.
const assetPaths = (source, prefix) => source.replace(/(href|src)="([^"#]+\.(?:css|mjs|js|sql))"/g, (_, attr, path) => `${attr}="${prefix}${path}"`);
fs.writeFileSync(new URL('../index.html', import.meta.url), assetPaths(html, 'web/dist/'));
fs.writeFileSync(new URL('../admin/index.html', import.meta.url), assetPaths(read('workbench-ink-7c91.html'), '../web/dist/').replace('href="./"', 'href="../"'));
const css = read('style.css');
const engine = read('engine.mjs').replace(/^export /gm, '');
const stripModule = script => script.replace(/^import .*\n/gm, '').replace(/^export /gm, '');
const cloud = stripModule(read('config.mjs')) + '\n' + stripModule(read('dictionary-store.mjs')) + '\n' + stripModule(read('community-store.mjs')) + '\n' + stripModule(read('catalogue.mjs')) + '\n' + stripModule(read('contribution-tools.mjs')) + '\n' + stripModule(read('community-ui.mjs'));
const words = JSON.stringify(JSON.parse(read('words.json'))).replaceAll('<', '\\u003c');
const app = read('app.js').replace(/^import .*\n/gm, '').replace("await (await fetch(new URL('./words.json', import.meta.url))).json()", () => words);
// Callback replacements preserve literal JS sequences such as $' and $&.
// A replacement string would interpolate HTML suffixes into the script.
html = html.replace('<link rel="stylesheet" href="style.css">', () => '<style>' + css + '</style>');
html = html.replace('<link rel="stylesheet" href="dictionary.css">', () => '<style>' + read('dictionary.css') + '</style>');
html = html.replace('<link rel="stylesheet" href="community.css">', () => '<style>' + read('community.css') + '</style>');
html = html.replace('<link rel="stylesheet" href="catalogue.css">', () => '<style>' + read('catalogue.css') + '</style>');
const inlineScript = (engine + '\n' + stripModule(read('editor-model.mjs')) + '\n' + cloud + '\n' + app).replace(/<\/script/gi, '<\\/script');
html = html.replace('<script type="module" src="app.js"></script>', () => '<script type="module">\n' + inlineScript + '\n</script>');
fs.writeFileSync(new URL('./preview.html', import.meta.url), html);
const migration=fs.readFileSync(new URL('../supabase/migrations/20261017_community_moderation.sql',import.meta.url),'utf8');
const seeds=fs.readFileSync(new URL('../supabase/seeds/initial_dictionary.sql',import.meta.url),'utf8');
const reviewTools=fs.readFileSync(new URL('../supabase/migrations/20261018_review_tools.sql',import.meta.url),'utf8');
const entryChanges=fs.readFileSync(new URL('../supabase/migrations/20261018_entry_changes.sql',import.meta.url),'utf8');
const styleReview=fs.readFileSync(new URL('../supabase/migrations/20261018_style_review.sql',import.meta.url),'utf8');
const referenceApproval=referenceApprovalSql(JSON.parse(read('words.json')));
const publishedEdit=fs.readFileSync(new URL('../supabase/migrations/20261018_published_edit.sql',import.meta.url),'utf8');
fs.writeFileSync(new URL('./dist/published-edit-upgrade.sql',import.meta.url),publishedEdit);
fs.writeFileSync(new URL('./dist/reference-approval-upgrade.sql',import.meta.url),referenceApproval);
fs.writeFileSync(new URL('./dist/supabase-setup.sql',import.meta.url),migration+'\n'+seeds+'\n'+reviewTools+'\n'+entryChanges+'\n'+styleReview+'\n'+referenceApproval+'\n'+publishedEdit);
fs.writeFileSync(new URL('./dist/review-efficiency-upgrade.sql',import.meta.url),reviewTools+'\n'+entryChanges+'\n'+styleReview+'\n'+referenceApproval+'\n'+publishedEdit);
fs.writeFileSync(new URL('./dist/entry-changes-upgrade.sql',import.meta.url),reviewTools+'\n'+entryChanges);
fs.writeFileSync(new URL('./dist/review-tools-upgrade.sql',import.meta.url),reviewTools);
console.log('Created web/preview.html');
