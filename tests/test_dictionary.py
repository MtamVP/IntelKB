import json
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'scripts'))
from build_dictionary import build


class DictionaryTests(unittest.TestCase):
    def test_merge_sources_preserve_meanings_and_never_auto_approve(self):
        test_dir = pathlib.Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory(dir=test_dir, prefix='intelkb-test-') as tmp:
            root = pathlib.Path(tmp)
            assert root.resolve().is_relative_to(test_dir)
            upstream = root / 'data/processed/expansion_candidates.jsonl'
            editorial = root / 'data/editorial/expansions.jsonl'
            upstream.parent.mkdir(parents=True)
            editorial.parent.mkdir(parents=True)
            upstream.write_text(json.dumps({'trigger': 'XL', 'expansion': 'xin lỗi',
                'sources': [{'source_id': 'upstream'}]}) + '\n', encoding='utf-8')
            proposals = [
                {'trigger': 'xl', 'expansion': 'xin lỗi', 'category': 'chat',
                 'sources': [{'source_id': 'editorial'}]},
                {'trigger': 'xl', 'expansion': 'xạo lồn', 'category': 'profanity',
                 'sources': [{'source_id': 'editorial'}]},
            ]
            editorial.write_text(''.join(json.dumps(row) + '\n' for row in proposals), encoding='utf-8')
            summary = build(root)
            rows = [json.loads(line) for line in (root / 'data/compiled/dictionary.jsonl').read_text(encoding='utf-8').splitlines()]
            self.assertEqual(summary['pairs'], 2)
            self.assertTrue(all(row['ambiguous'] and not row['auto_replace'] for row in rows))
            polite = next(row for row in rows if row['expansion'] == 'xin lỗi')
            self.assertEqual(len(polite['sources']), 2)
            before = (root / 'data/compiled/dictionary.jsonl').read_bytes()
            build(root)
            self.assertEqual(before, (root / 'data/compiled/dictionary.jsonl').read_bytes())
            queue = (root / 'data/compiled/review_queue.jsonl').read_text(encoding='utf-8').splitlines()
            self.assertEqual(json.loads(queue[0])['expansion'], 'xạo lồn')


if __name__ == '__main__':
    unittest.main()
