#!/usr/bin/env python3
"""Summarize app-facing JSON inference result files."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


def contains_cjk(value: Any) -> bool:
    return bool(re.search(r"[\u4e00-\u9fff]", str(value or "")))


def extract_text(row: Any) -> str:
    if isinstance(row, dict):
        for key in ("response", "prediction", "text", "content", "output"):
            if row.get(key):
                return str(row[key])
    return str(row)


def parse_first_json(text: str) -> tuple[dict, str]:
    value = str(text or "").strip()
    if "<answer>" in value and "</answer>" in value:
        value = value.split("<answer>", 1)[1].split("</answer>", 1)[0].strip()
    start = value.find("{")
    if start < 0:
        raise ValueError("no JSON object")
    obj, end = json.JSONDecoder().raw_decode(value[start:])
    if not isinstance(obj, dict):
        raise ValueError("JSON root is not object")
    return obj, value[start + end :].strip()


def summarize(label: str, path: Path) -> None:
    rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    total = len(rows)
    starts = valid = strict = zh_rows = think = extra = items_total = 0
    previews: list[tuple[int, list[str], list[Any]]] = []

    for index, row in enumerate(rows, 1):
        text = extract_text(row)
        stripped = text.strip()
        starts += int(stripped.startswith("{"))
        think += int("<think" in stripped.lower() or "</think>" in stripped.lower())
        try:
            obj, trailing = parse_first_json(stripped)
            valid += 1
            extra += int(bool(trailing))
            try:
                json.loads(stripped)
                strict += 1
            except Exception:
                pass
            items = obj.get("items") if isinstance(obj.get("items"), list) else []
            items_total += len(items)
            names = [str(item.get("name_zh") or item.get("name") or "") for item in items if isinstance(item, dict)]
            kcal = [item.get("kcal100") or item.get("calories") for item in items if isinstance(item, dict)]
            zh_rows += int(any(contains_cjk(name) for name in names))
            previews.append((index, names[:3], kcal[:3]))
        except Exception as exc:
            previews.append((index, ["PARSE_FAIL"], [type(exc).__name__]))

    print(
        f"{label}\t{total}条\tstarts {starts}/{total}\tstrict_json {strict}/{total}\t"
        f"first_json {valid}/{total}\textra_after_json {extra}/{total}\t"
        f"zh_rows {zh_rows}/{total}\tthink {think}/{total}\titems {items_total}"
    )
    for preview in previews[:6]:
        print(f"  {preview}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("pairs", nargs="+", help="LABEL=PATH")
    args = parser.parse_args()
    for pair in args.pairs:
        label, raw_path = pair.split("=", 1)
        summarize(label, Path(raw_path))


if __name__ == "__main__":
    main()
