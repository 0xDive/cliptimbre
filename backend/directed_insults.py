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

REPORTING_CUES = frozenset({
    "слово", "слова", "словом", "фраза", "фразу", "фразы", "цитата", "цитирую",
    "например", "написано", "написали", "название", "означает",
    "word", "phrase", "quote", "quoting", "example", "means",
})
RUSSIAN_SUBJECTS = frozenset({"ты", "вы", "он", "она", "они"})
RUSSIAN_MODIFIERS = frozenset({"просто", "такой", "такая", "такие", "реально", "совсем", "полный", "полная"})
ENGLISH_SUBJECTS = (
    ("youre",), ("youre", "a"), ("youre", "an"), ("youre", "such", "a"),
    ("you", "are"), ("you", "are", "a"), ("you", "are", "an"), ("you", "are", "such", "a"),
    ("he", "is", "a"), ("she", "is", "a"), ("they", "are"),
)
ADDRESSABLE = re.compile(r"^(?:сука|сучка|суки|сучары|ебан\w*|охуел\w*|охуев\w*|туп(?:ой|ая|ые)|кончен\w*|bitch|stupid|dumb)$")
DIRECT_COMMANDS = frozenset({"иди", "идите", "пошел", "пошла", "пошли", "катись"})
COMMAND_TARGETS = frozenset({"нахуй", "нахрен", "нахуя", "хуй", "хую", "хер", "жопу"})


def direct_address(before: list[str], phrase: list[str], after: list[str]) -> bool:
    if not phrase or any(word in REPORTING_CUES for word in before):
        return False
    words_before_target = before + phrase[:-1]
    if phrase[-1] in COMMAND_TARGETS:
        command = tuple(words_before_target[-2:])
        if command and (command[-1] in DIRECT_COMMANDS or
                        (len(command) == 2 and command[0] in DIRECT_COMMANDS and command[1] in {"ты", "вы"})):
            return True
    if phrase[0] in {"fuck", "screw"} and (phrase + after)[1:2] == ["you"]:
        return True
    if any(tuple(before[-len(subject):]) == subject for subject in ENGLISH_SUBJECTS):
        return True
    while before and before[-1] in RUSSIAN_MODIFIERS:
        before = before[:-1]
    return bool(before and before[-1] in RUSSIAN_SUBJECTS)


def classify_personal_insults(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Use nearby words from the same uninterrupted phrase as address evidence."""
    relevant = {"directed_insult", "strong_profanity", "moderate_profanity"}
    for event in events:
        category = event["category"]
        if category not in relevant:
            continue
        phrase = event["phrase"].split()
        before = " ".join(event["_before"]).split()
        after = " ".join(event["_after"]).split()
        explicit = not event.get("_quoted", False) and direct_address(before, phrase, after)
        if category == "directed_insult":
            event["targeting"] = "explicit" if explicit else "uncertain"
            if explicit:
                event.update(severity="high", label="Personal attack — explicit target")
        elif explicit and phrase and (ADDRESSABLE.fullmatch(phrase[-1]) or phrase[-1] in COMMAND_TARGETS
                                      or phrase[0] in {"fuck", "screw"} and (phrase + after)[1:2] == ["you"]):
            event.update(category="directed_insult", severity="high", label="Personal attack — explicit target",
                         targeting="explicit")

    personal = sorted((event for event in events if event["category"] == "directed_insult"), key=lambda e: e["start"])
    starts = [event["start"] for event in personal]
    out = []
    for event in events:
        if event["category"] in {"strong_profanity", "moderate_profanity"}:
            index = bisect.bisect_left(starts, event["start"] - 0.12)
            duplicate = next((p for p in personal[index:bisect.bisect_right(starts, event["start"] + 0.12)]
                              if abs(p["end"] - event["end"]) <= 0.12
                              and min(p["end"], event["end"]) > max(p["start"], event["start"])), None)
            if duplicate is not None:
                duplicate["profanity"] = True
                continue
        out.append(event)
    return out
