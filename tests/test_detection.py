from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))

from pauses import find_pause_candidates
from profanity import load_rules, review_transcript
from video_pauses import freeze_candidates, parse_crop


def word(text, start, end=None, probability=0.93):
    return {"word": text, "start": start, "end": start + 0.21 if end is None else end,
            "probability": probability}


class ProfanityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rules = load_rules(ROOT / "ad_safety_terms.default.json")

    def scan(self, *chunks):
        return review_transcript([{"words": chunk} for chunk in chunks], self.rules)[0]

    def test_adjacent_chunks_supply_address_context_and_keep_word_bounds(self):
        events = self.scan([word("ты", 4.0)], [word("мудак", 4.23, 4.46)])
        self.assertEqual(len(events), 1)
        event = events[0]
        self.assertEqual((event["start"], event["end"]), (4.23, 4.46))
        self.assertEqual((event["severity"], event["category"]), ("high", "directed_insult"))
        self.assertTrue(event["auto_censor"])

    def test_sentence_boundary_quotes_and_low_confidence_stay_in_review(self):
        separate = self.scan([word("ты.", 1), word("идиот", 1.3)])[0]
        quoted = self.scan([word("«ты", 1), word("идиот»", 1.3)])[0]
        weak = self.scan([word("ты", 1), word("мудак", 1.3, probability=.21)])[0]
        self.assertTrue(all(event["severity"] == "review" for event in (separate, quoted, weak)))
        self.assertFalse(weak["auto_censor"])

    def test_inflected_swears_match_without_matching_benign_substrings(self):
        events = self.scan([word("учёба", 1), word("страхуй", 1.3), word("ёбаного", 1.6), word("охуели", 1.9)])
        self.assertEqual([event["phrase"] for event in events], ["ебаного", "охуели"])

    def test_overlapping_asr_tokens_merge_but_repeated_words_remain(self):
        events = self.scan(
            [word("fuck", 1, 1.16, probability=.71), word("fuck", 1.17, 1.33)],
            [word("fuck", 1.01, 1.16, probability=.96)],
        )
        self.assertEqual([event["start"] for event in events], [1.01, 1.17])
        self.assertEqual(events[0]["confidence"], .96)

    def test_repeated_profanity_summary_is_local_and_review_only(self):
        events = self.scan([word("fuck", 600 + i * 4) for i in range(6)])
        cluster = next(event for event in events if event["category"] == "frequent_profanity")
        self.assertEqual(cluster["start"], 600)
        self.assertGreater(cluster["end"], 620)
        self.assertFalse(cluster["auto_censor"])


class SpeechPauseTests(unittest.TestCase):
    settings = dict(
        min_pause=.8, target_pause=.22, max_auto_pause=4,
        review_max_pause=8, edge_protect=1.5, min_delete=.35,
    )

    def test_only_confirmed_interior_pause_can_be_tightened(self):
        regions = [{"start": 0, "end": 10}]
        speech = [(0, 1), (2, 4), (5, 6), (7, 10)]
        matches = [{"start": 0, "end": 4}, {"start": 5, "end": 6}]
        pauses = find_pause_candidates(regions, speech, **self.settings, speech_matches=matches)
        self.assertEqual([pause["action"] for pause in pauses], ["review", "auto", "review"])
        self.assertEqual([pause["reason"] for pause in pauses], ["near_boundary", "", "unconfirmed_voice"])
        self.assertAlmostEqual(pauses[1]["delete_duration"], .78)

    def test_long_gap_between_distinct_confirmed_voice_regions_is_reviewable(self):
        matches = [{"start": 0, "end": 3}, {"start": 9, "end": 12}]
        [pause] = find_pause_candidates(matches, [(0, 3), (9, 12)], **self.settings, speech_matches=matches)
        self.assertEqual((pause["start"], pause["end"], pause["reason"]), (3, 9, "long"))


class VideoPauseTests(unittest.TestCase):
    def test_validated_crop_and_complete_middle_hold(self):
        self.assertEqual(parse_crop("0, 5, 75, 90"), (0, 5, 75, 90))
        with self.assertRaises(ValueError):
            parse_crop("90,0,20,100")
        log = "\n".join(f"lavfi.freezedetect.freeze_{event}: {second}" for event, second in (
            ("start", 0), ("end", 2), ("start", 4), ("end", 6.5), ("start", 8),
        ))
        self.assertEqual(freeze_candidates(log, 12), [(4, 6.5)])

    def test_one_cut_between_static_slides_is_not_a_resume(self):
        log = "\n".join(f"lavfi.freezedetect.freeze_{event}: {second}" for event, second in (
            ("start", 2), ("end", 4), ("start", 4),
        ))
        self.assertEqual(freeze_candidates(log, 9), [])
