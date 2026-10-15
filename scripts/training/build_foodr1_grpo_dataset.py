#!/usr/bin/env python3
"""Convert the compact SFT set into Food-R1-style GRPO data.

The public Food-R1 training recipe uses a cold-start SFT stage followed by
GRPO with rewards over a strict English ingredient/calorie answer format.
This script keeps our current official-data subset but rewrites supervision
into that reward format so ms-swift can pass `solution` and `dataset` to the
Food-R1 reward plugin.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


FOODR1_GRPO_PROMPT = """Analyze the food image and estimate the dish name, visible ingredients, ingredient quantities, and total calories.
Return exactly in this format:
<think>brief food reasoning</think>
<answer>The dish is DISH, and has N ingredients in total. They are: QTY UNIT ingredient, ... . They have a total of K kcal.</answer>"""


def _load_target(row: dict[str, Any]) -> dict[str, Any] | None:
    messages = row.get("messages") or []
    for msg in reversed(messages):
        if msg.get("role") != "assistant":
            continue
        try:
            target = json.loads(msg.get("content") or "")
        except Exception:
            continue
        if isinstance(target, dict) and isinstance(target.get("items"), list):
            return target
    return None


def _clean_en(value: str) -> str:
    value = str(value or "").strip().lower().replace("_", " ")
    keep = []
    for ch in value:
        if ch.isalnum() or ch in {" ", "-", "'"}:
            keep.append(ch)
        else:
            keep.append(" ")
    return " ".join("".join(keep).split()) or "food"


def _official_answer(items: list[dict[str, Any]]) -> str:
    usable = []
    for item in items:
        name = _clean_en(item.get("detector_phrase") or item.get("name_zh") or "food")
        kcal100 = float(item.get("kcal100") or 0)
        if kcal100 <= 0:
            continue
        usable.append((name, kcal100))
    if not usable:
        usable = [("food", 100.0)]

    dish = usable[0][0] if len(usable) == 1 else "mixed food"
    parts = [f"100 g {name}" for name, _ in usable]
    total_kcal = round(sum(kcal for _, kcal in usable), 1)
    if total_kcal.is_integer():
        total_text = str(int(total_kcal))
    else:
        total_text = f"{total_kcal:.1f}"

    answer = (
        f"The dish is {dish}, and has {len(usable)} ingredients in total. "
        f"They are: {', '.join(parts)}. "
        f"They have a total of {total_text} kcal."
    )
    think = (
        "I identify the visible food items, normalize each item to a 100 g "
        "edible portion, and sum the calories from the nutrition density."
    )
    return f"<think>{think}</think><answer>{answer}</answer>"


def convert_row(row: dict[str, Any]) -> dict[str, Any] | None:
    target = _load_target(row)
    if not target:
        return None
    items = [item for item in target.get("items", []) if isinstance(item, dict)]
    if not items:
        return None

    sample: dict[str, Any] = {
        "messages": [{"role": "user", "content": FOODR1_GRPO_PROMPT}],
        "solution": _official_answer(items),
        "dataset": "caloriebench_80k",
        "metadata": {
            "source": row.get("metadata", {}).get("source", ""),
            "converted_from": "official_foodr1_sft",
        },
    }
    images = row.get("images")
    if images:
        sample["messages"][0]["content"] = "<image>\n" + FOODR1_GRPO_PROMPT
        sample["images"] = images
    return sample


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--input",
        default="/root/autodl-tmp/glm_food_r1_experiment/data/official_foodr1_sft.jsonl",
    )
    parser.add_argument(
        "--output",
        default="/root/autodl-tmp/glm_food_r1_experiment/data/official_foodr1_grpo.jsonl",
    )
    parser.add_argument("--limit", type=int, default=0)
    args = parser.parse_args()

    in_path = Path(args.input)
    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    count = 0
    with in_path.open("r", encoding="utf-8") as src, out_path.open("w", encoding="utf-8") as dst:
        for line in src:
            row = json.loads(line)
            sample = convert_row(row)
            if sample is None:
                continue
            dst.write(json.dumps(sample, ensure_ascii=False, separators=(",", ":")) + "\n")
            count += 1
            if args.limit and count >= args.limit:
                break
    print(f"wrote {count} Food-R1-style GRPO samples to {out_path}")


if __name__ == "__main__":
    main()
