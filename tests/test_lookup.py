import pathlib
import sys
import unittest
import unicodedata

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'scripts'))
from lookup import suggest


class LookupTests(unittest.TestCase):
    def test_no_substring_match(self):
        self.assertEqual(suggest('keyboard IntelKB', {'k': [{}]})['matches'], [])

    def test_case_and_punctuation(self):
        result = suggest('ĐCMM! ko?', {'đcmm': [{}], 'ko': [{}]})
        self.assertEqual([m['typed'] for m in result['matches']], ['ĐCMM', 'ko'])

    def test_unicode_normalization_and_offsets(self):
        result = suggest('🙂 ' + unicodedata.normalize('NFD', 'đc'), {'đc': [{}]})
        match = result['matches'][0]
        self.assertEqual(result['normalized_text'][match['start']:match['end']], 'đc')

    def test_longest_phrase_first(self):
        result = suggest('z là sao', {'z': [{}], 'z là': [{}]})
        self.assertEqual(result['matches'][0]['typed'], 'z là')

    def test_never_bridge_punctuation(self):
        self.assertEqual(suggest('z, là', {'z là': [{}]})['matches'], [])

    def test_preserve_ambiguity_and_input(self):
        result = suggest('xl', {'xl': [{'expansion': 'xin lỗi'}, {'expansion': 'xạo lồn'}]})
        self.assertTrue(result['matches'][0]['ambiguous'])
        self.assertEqual(len(result['matches'][0]['suggestions']), 2)
        self.assertEqual(result['normalized_text'], 'xl')


if __name__ == '__main__':
    unittest.main()
