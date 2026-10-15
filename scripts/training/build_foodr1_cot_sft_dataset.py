#!/usr/bin/env python3
"""Build Food-R1-style CoT SFT data from the GRPO JSONL.

Food-R1 uses a cold-start CoT SFT stage before GRPO. This converts rows with
`messages` + `solution` into normal chat SFT rows where the assistant response
is the official-format `<think>...</think><answer>...</answer>` solution.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def convert(row: dict[str, Any]) -> dict[str, Any] | None:
    messages = row.get("messages") or []
    solution = row.get("solution")
    if not messages or not isinstance(solution, str) or not solution.strip():
        return None
    sample: dict[str, Any] = {
        "messages": [
            {"role": "user", "content": messages[0].get("content", "")},
            {"role": "assistant", "content": solution},
        ],
        "metadata": {
            **(row.get("metadata") or {}),
            "stage": "foodr1_cot_sft",
        },
    }
    if row.get("images"):
        sample["images"] = row["images"]
    return sample


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--input",
        default="/root/autodl-tmp/glm_food_r1_experiment/data/official_foodr1_grpo.jsonl",
    )
    parser.add_argument(
        "--output",
        default="/root/autodl-tmp/glm_food_r1_experiment/data/official_foodr1_cot_sft.jsonl",
    )
    parser.add_argument("--limit", type=int, default=0)
    args = parser.parse_args()

    in_path = Path(args.input)
    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    count = 0
    with in_path.open("r", encoding="utf-8") as src, out_path.open("w", encoding="utf-8") as dst:
        for line in src:
            sample = convert(json.loads(line))
            if sample is None:
                continue
            dst.write(json.dumps(sample, ensure_ascii=False, separators=(",", ":")) + "\n")
            count += 1
            if args.limit and count >= args.limit:
                break
    print(f"wrote {count} Food-R1-style CoT SFT samples to {out_path}")


if __name__ == "__main__":
    main()
