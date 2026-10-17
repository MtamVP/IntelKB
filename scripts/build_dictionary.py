"""Build a local lookup dictionary without downloading or changing raw data."""
import collections
import hashlib
import json
import pathlib
import unicodedata

ROOT = pathlib.Path(__file__).resolve().parents[1]


def key(text):
    return ' '.join(unicodedata.normalize('NFC', text).casefold().split())


def read_rows(path):
    with path.open(encoding='utf-8') as stream:
        return [json.loads(line) for line in stream if line.strip()]


def build(root=ROOT):
    merged = {}
    files = [root / 'data/processed/expansion_candidates.jsonl',
             root / 'data/editorial/expansions.jsonl']
    for path in files:
        for row in read_rows(path):
            trigger, expansion = key(row['trigger']), key(row['expansion'])
            if not trigger or not expansion or trigger == expansion:
                continue
            pair = (trigger, expansion)
            entry = merged.setdefault(pair, {
                'id': hashlib.sha256(('\0'.join(pair)).encode()).hexdigest()[:16],
                'trigger': trigger, 'expansion': expansion,
                'editorial_proposal': False, 'categories': [], 'examples': [],
                'sources': [], 'review_status': 'unreviewed', 'auto_replace': False,
            })
            if path.parent.name == 'editorial':
                entry['editorial_proposal'] = True
                entry['categories'] = sorted(set(entry['categories'] + [row['category']]))
                entry['examples'] = row.get('examples', [])
            for source in row['sources']:
                if source not in entry['sources']:
                    entry['sources'].append(source)
    grouped = collections.defaultdict(list)
    for entry in merged.values():
        grouped[entry['trigger']].append(entry)
    records = []
    for trigger in sorted(grouped):
        options = sorted(grouped[trigger], key=lambda e: (not e['editorial_proposal'], e['expansion']))
        for entry in options:
            entry['ambiguous'] = len(options) > 1
            records.append(entry)
    out = root / 'data/compiled'
    out.mkdir(parents=True, exist_ok=True)
    (out / 'dictionary.jsonl').write_text(
        ''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in records), encoding='utf-8')
    # Put explicit profanity proposals and ambiguous entries first for human review.
    queue = sorted(records, key=lambda e: (
        'profanity' not in e['categories'], not e['ambiguous'],
        not e['editorial_proposal'], e['trigger'], e['expansion']))
    (out / 'review_queue.jsonl').write_text(
        ''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in queue), encoding='utf-8')
    summary = {
        'pairs': len(records), 'triggers': len(grouped),
        'ambiguous_triggers': sum(len(options) > 1 for options in grouped.values()),
        'editorial_proposals': sum(e['editorial_proposal'] for e in records),
        'approved_for_auto_replace': 0,
    }
    (out / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    return summary


if __name__ == '__main__':
    print(json.dumps(build(), ensure_ascii=False, indent=2))
