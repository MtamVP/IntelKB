"""Inspect expansion suggestions locally. Never rewrites the user's text."""
import argparse
import collections
import json
import pathlib
import re
import sys
import unicodedata

ROOT = pathlib.Path(__file__).resolve().parents[1]


def load_index(path=ROOT / 'data/compiled/dictionary.jsonl'):
    index = collections.defaultdict(list)
    with path.open(encoding='utf-8') as stream:
        for line in stream:
            row = json.loads(line)
            index[row['trigger']].append(row)
    return index


def suggest(text, index):
    # NFC offsets refer to the returned normalized_text, not the original string.
    text = unicodedata.normalize('NFC', text)
    # Unicode word tokens prevent matching `k` inside a name or a word.
    tokens = list(re.finditer(r'\w+(?:[\u0300-\u036f]+\w*)*', text))
    matches = []
    max_tokens = max((len(k.split()) for k in index), default=1)
    i = 0
    while i < len(tokens):
        found = None
        for count in range(min(max_tokens, len(tokens) - i), 0, -1):
            chosen = tokens[i:i + count]
            # Phrase matching can bridge whitespace, never punctuation.
            if any(not text[a.end():b.start()].isspace() for a, b in zip(chosen, chosen[1:])):
                continue
            trigger = ' '.join(t.group().casefold() for t in chosen)
            if trigger in index:
                found = (count, chosen, trigger)
                break
        if found:
            count, chosen, trigger = found
            matches.append({
                'start': chosen[0].start(), 'end': chosen[-1].end(),
                'typed': text[chosen[0].start():chosen[-1].end()],
                'ambiguous': len(index[trigger]) > 1,
                'suggestions': index[trigger],
            })
            i += count
        else:
            i += 1
    return {'normalized_text': text, 'offset_unit': 'python_unicode_code_points',
            'matches': matches}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('text', help='Sentence or abbreviation to inspect')
    parser.add_argument('--json', action='store_true', help='Print full JSON with provenance and offsets')
    args = parser.parse_args()
    sys.stdout.reconfigure(encoding='utf-8')
    path = ROOT / 'data/compiled/dictionary.jsonl'
    if not path.exists():
        parser.error('Run python scripts/build_dictionary.py first')
    result = suggest(args.text, load_index(path))
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        lines = ['Câu nhập: ' + result['normalized_text'], '', 'Gợi ý từ điển:']
        for match in result['matches']:
            options = ' / '.join(row['expansion'] for row in match['suggestions'])
            note = ' [nhiều nghĩa]' if match['ambiguous'] else ''
            lines.append('  ' + match['typed'] + ' → ' + options + note)
        if not result['matches']:
            lines.append('  Chưa tìm thấy từ phù hợp trong từ điển.')
        lines.extend(['', 'Chưa lọc theo ngữ cảnh; câu nhập được giữ nguyên.'])
        print('\n'.join(lines))


if __name__ == '__main__':
    main()
