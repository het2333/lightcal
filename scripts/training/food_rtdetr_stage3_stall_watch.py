#!/usr/bin/env python3
"""Lightweight stage3 training stall diagnostics.

This watchdog only records suspected stalls. It never kills or restarts training.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import time
from pathlib import Path
from typing import Any


PROGRESS_PATTERN = re.compile(
    r"Epoch: \[(\d+)\]\s+\[\s*(\d+)/(\d+)\].*?loss: ([0-9.]+) \(([0-9.]+)\)"
)
FAILURE_PATTERN = re.compile(
    r"Traceback|CUDA out of memory|RuntimeError|Exception|Killed|No space|"
    r"FileNotFoundError|ValueError|AssertionError|index out of bounds|device-side assert",
    re.IGNORECASE,
)


def parse_train_log_text(text: str) -> tuple[dict[str, Any] | None, list[str]]:
    latest: dict[str, Any] | None = None
    failures: list[str] = []
    for line in text.splitlines():
        match = PROGRESS_PATTERN.search(line)
        if match:
            latest = {
                "epoch": int(match.group(1)),
                "iteration": int(match.group(2)),
                "total": int(match.group(3)),
                "loss": float(match.group(4)),
                "loss_avg": float(match.group(5)),
            }
        if FAILURE_PATTERN.search(line):
            failures.append(line.strip())
    return latest, failures


def parse_train_log(path: Path) -> tuple[dict[str, Any] | None, list[str]]:
    if not path.exists():
        return None, []
    return parse_train_log_text(path.read_text(encoding="utf-8", errors="ignore"))


def build_stall_record(
    *,
    latest: dict[str, Any] | None,
    failure_count: int,
    previous_key: tuple[int, int] | None,
    stagnant_checks: int,
    threshold: int,
) -> tuple[dict[str, Any], tuple[int, int] | None, int]:
    key = None if latest is None else (int(latest["epoch"]), int(latest["iteration"]))
    next_stagnant = stagnant_checks + 1 if key is not None and key == previous_key else 0
    status = "stalled_suspect" if next_stagnant >= threshold else "ok"
    return (
        {
            "timestamp": time.strftime("%F %T"),
            "latest": latest,
            "failure_count": failure_count,
            "stagnant_checks": next_stagnant,
            "status": status,
        },
        key,
        next_stagnant,
    )


def collect_diagnostics() -> str:
    command = (
        "screen -ls; "
        "nvidia-smi --query-gpu=index,memory.used,memory.total,utilization.gpu,temperature.gpu,power.draw "
        "--format=csv,noheader; "
        "ps -eo pid,ppid,stat,etime,pcpu,pmem,args | "
        "grep -E 'tools/train.py|stage3_full_train' | grep -v grep; "
        "df -h /root/autodl-tmp"
    )
    completed = subprocess.run(
        ["bash", "-lc", command],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=30,
    )
    return completed.stdout[-6000:]


def append_jsonl(path: Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, ensure_ascii=False) + "\n")


def watch(
    *,
    train_log: Path,
    output_log: Path,
    interval_seconds: int,
    threshold: int,
    once: bool,
) -> None:
    previous_key: tuple[int, int] | None = None
    stagnant_checks = 0
    append_jsonl(output_log, {"timestamp": time.strftime("%F %T"), "event": "stall_watch_started"})

    while True:
        latest, failures = parse_train_log(train_log)
        record, previous_key, stagnant_checks = build_stall_record(
            latest=latest,
            failure_count=len(failures),
            previous_key=previous_key,
            stagnant_checks=stagnant_checks,
            threshold=threshold,
        )
        if record["status"] == "stalled_suspect":
            record["diagnostics_tail"] = collect_diagnostics()
        append_jsonl(output_log, record)
        if once:
            return
        time.sleep(interval_seconds)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--train-log",
        type=Path,
        default=Path("/root/autodl-tmp/food_rtdetr_stage3/logs/stage3_full_train.log"),
    )
    parser.add_argument(
        "--output-log",
        type=Path,
        default=Path("/root/autodl-tmp/food_rtdetr_stage3/logs/stage3_stall_watch.log"),
    )
    parser.add_argument("--interval-seconds", type=int, default=600)
    parser.add_argument("--threshold", type=int, default=3)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    watch(
        train_log=args.train_log,
        output_log=args.output_log,
        interval_seconds=args.interval_seconds,
        threshold=args.threshold,
        once=args.once,
    )


if __name__ == "__main__":
    main()
