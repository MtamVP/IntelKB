"""Export only IntelKB-authored proposals, never third-party raw datasets."""
import json
import pathlib

root = pathlib.Path(__file__).resolve().parents[1]
rows = [json.loads(line) for line in (root / 'data/editorial/expansions.jsonl').read_text(encoding='utf-8').splitlines() if line.strip()]
words = [{'trigger': row['trigger'], 'expansion': row['expansion'], 'category': row['category']} for row in rows]
(root / 'web/dist/words.json').write_text(json.dumps(words, ensure_ascii=False), encoding='utf-8')
print(f'Exported {len(words)} original editorial proposals.')
