"""Context-sensitive personal insult detection for audio-only YouTube review.

This is a deliberately *conservative heuristic*, not harassment detection or a
prediction of YouTube's decision.  It flags personal insults for human review
and elevates clear second-/third-person attacks above isolated interjections.

Events keep word-level timestamps so Timeline Mute/Beep censor the relevant word
rather than the whole speech segment.  The classifier works with older local
risk dictionaries too; new dictionary rules are preferred when present.
"""

from __future__ import annotations

import bisect
import re
from typing import Any

# Also shipped in ad_safety_terms.default.json. These built-in fallbacks keep
# the new category available to existing installations with a customized
# ad_safety_terms.json that has no directed_insult rules yet.
DEFAULT_INSULT_RULES: tuple[dict[str, Any], ...] = (
    {
        "id": "ru_personal_insults",
        "category": "directed_insult",
        "severity": "review",
        "label": "Possible personal insult",
        "patterns": [
            r"\b(?:еблан\w*|ебала[йяиюе]\w*|ебанут\w*|долбоеб\w*|долбаеб\w*|уеб(?:ок|к|ищ)\w*|хуесос\w*|пиздюк\w*|мудак\w*|мудач\w*|мудил\w*|дебил\w*|идиот\w*|кретин\w*|придур(?:ок|к)\w*|ублюдок\w*|тупиц\w*|твар(?:ь|и|ю|ям|ями|юг\w*)|урод(?:а|у|ом|ы|ов|ам|ами|ина|ины|иной)?|сучар\w*|гандон\w*)\b",
        ],
    },
    {
        "id": "en_personal_insults",
        "category": "directed_insult",
        "severity": "review",
        "label": "Possible personal insult",
        "patterns": [
            r"\b(?:asshole\w*|dumbass\w*|idiot\w*|moron\w*|imbecile\w*|scumbag\w*|loser\w*|bastard\w*|jerk\w*)\b",
        ],
    },
)

# Direct human-address terms. Avoid treating generic exclamations such as
# "блять"/"fuck" as attacks, even when somebody is speaking to another person.
ADDRESS_CUES = frozenset({
    "ты", "тебя", "тебе", "тобой", "твой", "твоя", "твои", "твою", "твоего",
    "вы", "вас", "вам", "вами", "ваш", "ваша", "ваши", "вашего",
    "он", "она", "они", "его", "ее", "их", "этот", "эта", "эти", "тот", "та",
    "такие", "такой", "такая", "того", "этого", "все", "каждый", "каждая",
    "you", "your", "you're", "youre", "he", "she", "they", "him", "her", "that", "this",
})
REPORTING_CUES = frozenset({
    "слово", "слова", "словом", "фраза", "фразу", "фразы", "цитата", "цитирую",
    "например", "написано", "написали", "название", "означает", "говорится",
    "word", "phrase", "quote", "quoting", "example", "means",
})
SECOND_PERSON_REQUIRES_CONTEXT = (
    re.compile(r"^(?:сука|сучка|суки|сучары|ебан\w*|охуел\w*|охуев\w*|туп(?:ой|ая|ые|ого|ому|ым)|кончен\w*|бич\w*|bitch|stupid|dumb)$", re.I),
)
DIRECT_COMMANDS = frozenset({"иди", "идите", "пошел", "пошла", "пошли", "пошли", "отвали", "катись", "go", "get"})
COMMAND_TARGETS = re.compile(r"^(?:нахуй|наху[йяие]|хуй|хую|хер|жопу|away|off)$", re.I)


def canonical_word(value: str) -> str:
    return re.sub(r"[^a-zа-я0-9]+", "", str(value).lower().replace("ё", "е"))


def _word_stream(segments: list[dict[str, Any]]) -> list[dict[str, Any]]:
    tokens: list[dict[str, Any]] = []
    for seg in segments:
        for word in seg.get("words") or []:
            # Word timestamps, not segment timestamps, are the source of truth.
            try:
                start, end = float(word["start"]), float(word["end"])
            except (TypeError, ValueError, KeyError):
                continue
            norm = canonical_word(word.get("norm") or word.get("word") or "")
            if norm and end >= start:
                tokens.append({"start": start, "end": end, "norm": norm})
    tokens.sort(key=lambda w: (w["start"], w["end"]))
    return tokens


def _neighbors(words: list[dict[str, Any]], starts: list[float], event: dict[str, Any]) -> tuple[list[str], list[str]]:
    a = float(event["start"])
    b = float(event["end"])
    left_idx = bisect.bisect_left(starts, a - 2.3)
    right_idx = bisect.bisect_right(starts, b + 2.3)
    before: list[str] = []
    after: list[str] = []
    for word in words[left_idx:right_idx]:
        if word["end"] <= a + 0.04 and a - word["end"] <= 2.3:
            before.append(word["norm"])
        elif word["start"] >= b - 0.04 and word["start"] - b <= 2.3:
            after.append(word["norm"])
    # Limit to four adjacent tokens on each side; unrelated earlier sentences
    # must not turn lone "еблан" into an explicit personal attack.
    return before[-4:], after[:4]


def _is_direct_command(word: str, before: list[str], after: list[str]) -> bool:
    if not COMMAND_TARGETS.fullmatch(word):
        return False
    # "иди нахуй" and "пошёл ты нахуй" (including split-sentence Whisper words).
    return any(candidate in DIRECT_COMMANDS for candidate in before[-3:]) or (
        bool(after) and after[0] in DIRECT_COMMANDS
    )


def _is_addressable_swear(word: str) -> bool:
    return any(p.fullmatch(word) for p in SECOND_PERSON_REQUIRES_CONTEXT)


def classify_personal_insults(
    events: list[dict[str, Any]],
    segments: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """Classify context-sensitive attacks; keep one marker per word.

    Recognize cross-segment pronouns/imperatives but downgrade quotes and vague
    mentions to REVIEW.  Preserve hateful/slur labels, which have their own
    higher-priority review policy.  Can be called before or after deduplication.
    """
    words = _word_stream(segments)
    starts = [w["start"] for w in words]
    for event in events:
        category = str(event.get("category", ""))
        if category not in {"directed_insult", "strong_profanity", "moderate_profanity"}:
            continue
        phrase = canonical_word(event.get("phrase", ""))
        if not phrase:
            continue
        before, after = _neighbors(words, starts, event)
        evidence = [w for w in before + after if w in ADDRESS_CUES]
        report_mention = any(w in REPORTING_CUES for w in before[-4:])
        command = _is_direct_command(phrase, before, after) or (
            phrase in {"fuck", "fucking", "screw"} and bool(after) and after[0] == "you"
        )
        explicit_target = (bool(evidence) and not report_mention) or command

        if category == "directed_insult":
            # Preserve an explicit HIGH severity in a user-edited risk rule.
            # Our shipped defaults use REVIEW for ambiguous standalone terms.
            custom_high = str(event.get("severity", "review")) == "high"
            event["severity"] = "high" if explicit_target or custom_high else "review"
            event["label"] = ("Personal attack — explicit target" if explicit_target
                              else "Personal insult — verify context")
            event["rule"] = "person_directed_explicit" if explicit_target else str(event.get("rule", "personal_insult"))
            event["targeting"] = "explicit" if explicit_target else "uncertain"
            continue

        # Interjections do not count as person-directed insults by themselves.
        if not explicit_target or not (_is_addressable_swear(phrase) or command):
            continue
        event.update({
            "category": "directed_insult",
            "severity": "high",
            "rule": "person_directed_context",
            "label": "Personal attack — explicit target",
            "targeting": "explicit",
        })

    # The lexicon also matches some terms flagged by the generic profanity
    # dictionary. One word must not create two censorship intervals/markers.
    personal = [e for e in events if e.get("category") == "directed_insult"]
    out: list[dict[str, Any]] = []
    for event in events:
        if event.get("category") in {"strong_profanity", "moderate_profanity"}:
            a, b = float(event["start"]), float(event["end"])
            if any(
                abs(a - float(p["start"])) <= 0.12
                and abs(b - float(p["end"])) <= 0.18
                for p in personal
            ):
                continue
        out.append(event)
    return out
