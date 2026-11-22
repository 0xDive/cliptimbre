"""Match local review rules against Whisper's timed words."""

from __future__ import annotations

from bisect import bisect_left, bisect_right
from dataclasses import dataclass
import json
import math
from pathlib import Path
import re
import unicodedata

from directed_insults import DEFAULT_INSULT_RULES, classify_personal_insults


MIN_CENSOR_CONFIDENCE = 0.55
PROFANITY = {"strong_profanity", "moderate_profanity"}


def normalize_text(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).casefold().replace("ё", "е")
    text = re.sub(r"(?<=\w)['’](?=\w)", "", text)
    return " ".join(re.sub(r"[^\w-]+", " ", text).split())


@dataclass(frozen=True)
class Rule:
    id: str
    category: str
    severity: str
    label: str
    patterns: tuple[re.Pattern[str], ...]


def load_rules(path: Path) -> list[Rule]:
    payload = json.loads(path.read_text(encoding="utf-8-sig"))
    raw_rules = list(payload.get("rules") or [])
    if not any(raw.get("patterns") for raw in raw_rules):
        raise ValueError(f"No ad-safety rules found in {path}")
    if not any(raw.get("category") == "directed_insult" for raw in raw_rules):
        raw_rules.extend(DEFAULT_INSULT_RULES)
    rules = []
    for raw in raw_rules:
        category = str(raw.get("category") or "review")
        key = str(raw.get("id") or category)
        severity = str(raw.get("severity") or "review").lower()
        if severity not in {"review", "high"}:
            raise ValueError(f"Rule {key}: severity must be review or high")
        try:
            patterns = tuple(
                re.compile(pattern.replace("ё", "е").replace("Ё", "Е"), re.IGNORECASE)
                for pattern in raw.get("patterns") or []
            )
        except re.error as exc:
            raise ValueError(f"Rule {key}: {exc}") from exc
        if patterns:
            rules.append(Rule(key, category, severity, str(raw.get("label") or category), patterns))
    if not rules:
        raise ValueError(f"No ad-safety patterns found in {path}")
    return rules


def timed_words(segments: list[dict]) -> list[dict]:
    words = []
    for segment in segments:
        for word in segment.get("words") or ():
            try:
                start, end = float(word["start"]), float(word["end"])
                probability = float(word.get("probability") or 0.0)
            except (TypeError, ValueError, KeyError):
                continue
            raw = str(word.get("word") or "").strip()
            normalized = normalize_text(raw or str(word.get("norm") or ""))
            if normalized and math.isfinite(end) and 0 <= start < end:
                probability = probability if 0 <= probability <= 1 else 0.0
                words.append({"start": start, "end": end, "norm": normalized, "word": raw or normalized,
                              "probability": probability})
    words.sort(key=lambda word: (word["start"], word["end"]))
    unique = []
    for word in words:
        previous = unique[-1] if unique else None
        if previous and previous["norm"] == word["norm"] and same_occurrence(previous, word):
            if word["probability"] > previous["probability"]:
                unique[-1] = word
        else:
            unique.append(word)
    return unique


def same_occurrence(a: dict, b: dict) -> bool:
    overlap = min(a["end"], b["end"]) - max(a["start"], b["start"])
    shorter = min(a["end"] - a["start"], b["end"] - b["start"])
    return shorter > 0 and overlap >= shorter * 0.60


def phrases(words: list[dict]):
    start = 0
    for index in range(1, len(words)):
        previous = words[index - 1]
        sentence_end = previous["word"].rstrip('»”\'"').endswith((".", "!", "?", "…"))
        if sentence_end or words[index]["start"] - previous["end"] > 0.65:
            yield words[start:index]
            start = index
    if words:
        yield words[start:]


def match_phrase(words: list[dict], rules: list[Rule]) -> list[dict]:
    starts, ends, cursor = [], [], 0
    for word in words:
        starts.append(cursor)
        ends.append(cursor + len(word["norm"]))
        cursor = ends[-1] + 1
    text = " ".join(word["norm"] for word in words)
    events = []
    for rule in rules:
        for pattern in rule.patterns:
            for match in pattern.finditer(text):
                first = bisect_right(ends, match.start())
                last = bisect_left(starts, match.end())
                if last <= first or match.start() == match.end():
                    continue
                tokens = words[first:last]
                confidence = min(word["probability"] for word in tokens)
                quote_context = " ".join(word["word"] for word in words[max(0, first - 8):first])
                quote_context += re.match(r"^\W*", tokens[0]["word"]).group()
                events.append({
                    "start": tokens[0]["start"],
                    "end": max(word["end"] for word in tokens),
                    "severity": rule.severity,
                    "category": rule.category,
                    "rule": rule.id,
                    "label": rule.label,
                    "phrase": match.group().strip(),
                    "context": " ".join(word["word"] for word in words[max(0, first - 8):last + 8]),
                    "confidence": confidence,
                    "auto_censor": confidence >= MIN_CENSOR_CONFIDENCE,
                    "_before": [word["norm"] for word in words[max(0, first - 4):first]],
                    "_after": [word["norm"] for word in words[last:last + 4]],
                    "_quoted": any(
                        quote_is_open(quote_context, opening, closing)
                        for opening, closing in (("«", "»"), ("“", "”"), ('"', '"'))
                    ),
                })
    return events


def quote_is_open(text: str, opening: str, closing: str) -> bool:
    if opening == closing:
        return text.count(opening) % 2 == 1
    return text.rfind(opening) > text.rfind(closing)


def deduplicate(events: list[dict]) -> list[dict]:
    selected = []

    def rank(event):
        return (
            event["auto_censor"], event["severity"] == "high",
            event["category"] == "strong_profanity", event["confidence"],
        )

    for event in sorted(events, key=lambda e: (e["start"], e["end"])):
        duplicate = None
        for index in range(len(selected) - 1, -1, -1):
            previous = selected[index]
            if previous["start"] < event["start"] - 0.25:
                break
            same_category = previous["category"] == event["category"] or (
                previous["category"] in PROFANITY and event["category"] in PROFANITY
            )
            if same_category and same_occurrence(previous, event):
                duplicate = index
                break
        if duplicate is None:
            selected.append(event)
        else:
            best = event if rank(event) > rank(selected[duplicate]) else selected[duplicate]
            if event.get("profanity") or selected[duplicate].get("profanity"):
                best["profanity"] = True
            selected[duplicate] = best
    return selected


def profanity_clusters(events: list[dict]) -> list[dict]:
    prof = [event for event in events if event.get("profanity") and event["auto_censor"]]
    clusters = []
    for index, event in enumerate(prof):
        count = 6
        last_index = index + count - 1
        if last_index >= len(prof) or prof[last_index]["start"] - event["start"] > 60:
            continue
        end = prof[last_index]["end"]
        if clusters and event["start"] <= clusters[-1]["end"]:
            clusters[-1]["end"] = max(clusters[-1]["end"], end)
            clusters[-1]["count"] = last_index - clusters[-1]["first_index"] + 1
        else:
            clusters.append({"start": event["start"], "end": end, "count": count, "first_index": index})
    return [
        {
            "start": cluster["start"], "end": cluster["end"], "severity": "review",
            "category": "frequent_profanity", "rule": "profanity_cluster", "label": "Frequent profanity",
            "phrase": f"{cluster['count']} flagged occurrences",
            "context": f"Repeated profanity over {cluster['end'] - cluster['start']:.1f} seconds",
            "confidence": 1.0, "auto_censor": False,
        }
        for cluster in clusters
    ]


def review_transcript(segments: list[dict], rules: list[Rule]) -> tuple[list[dict], int]:
    words = timed_words(segments)
    events = deduplicate([event for phrase in phrases(words) for event in match_phrase(phrase, rules)])
    for event in events:
        event["profanity"] = event["category"] in PROFANITY
    events = sorted(deduplicate(classify_personal_insults(events)), key=lambda event: event["start"])
    for event in events:
        event.pop("_before", None)
        event.pop("_after", None)
        event.pop("_quoted", None)
        if not event["auto_censor"]:
            event["severity"] = "review"
            event["label"] += " — uncertain transcription"
    events = sorted(events + profanity_clusters(events), key=lambda event: (event["start"], event["end"]))
    for number, event in enumerate(events, 1):
        event["index"] = number
    return events, len(words)
