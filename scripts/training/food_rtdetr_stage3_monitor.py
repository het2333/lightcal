#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import re
import subprocess
import time
from pathlib import Path
from typing import Any


DEFAULT_FAILURE_PATTERN = (
    r"Traceback|CUDA out of memory|RuntimeError|Exception|Killed|No space|"
    r"FileNotFoundError|ValueError|AssertionError|index out of bounds|device-side assert"
)
TRAIN_PROGRESS_RE = re.compile(r"Epoch: \[(\d+)\]\s+\[\s*(\d+)/(\d+)\]")
TEST_PROGRESS_RE = re.compile(r"Test:\s+\[\s*(\d+)/(\d+)\]")


def run_text(command: list[str]) -> dict[str, Any]:
    try:
        completed = subprocess.run(command, check=False, capture_output=True, text=True)
    except FileNotFoundError as exc:
        return {"returncode": 127, "stdout": "", "stderr": str(exc)}
    return {
        "returncode": completed.returncode,
        "stdout": completed.stdout.strip(),
        "stderr": completed.stderr.strip(),
    }


def parse_train_log_text(text: str, failure_pattern: str = DEFAULT_FAILURE_PATTERN) -> dict[str, Any]:
    latest_progress = ""
    epoch = None
    iteration = None
    total_iterations = None
    latest_test_progress = ""
    test_iteration = None
    test_total_iterations = None
    failure_re = re.compile(failure_pattern, re.IGNORECASE)
    failure_matches: list[str] = []

    for line in text.splitlines():
        train_match = TRAIN_PROGRESS_RE.search(line)
        if train_match:
            latest_progress = line
            epoch = int(train_match.group(1))
            iteration = int(train_match.group(2))
            total_iterations = int(train_match.group(3))

        test_match = TEST_PROGRESS_RE.search(line)
        if test_match:
            latest_test_progress = line
            test_iteration = int(test_match.group(1))
            test_total_iterations = int(test_match.group(2))

        if failure_re.search(line):
            failure_matches.append(line)

    return {
        "latest_progress": latest_progress,
        "epoch": epoch,
        "iteration": iteration,
        "total_iterations": total_iterations,
        "latest_test_progress": latest_test_progress,
        "test_iteration": test_iteration,
        "test_total_iterations": test_total_iterations,
        "failure_matches": failure_matches[-20:],
    }


def collect_status(
    *,
    screen_name: str,
    work_root: Path,
    train_log: Path,
    train_match: str,
    failure_pattern: str,
) -> dict[str, Any]:
    screen = run_text(["screen", "-ls"])
    processes = run_text(["ps", "-eo", "pid=,etime=,cmd="])
    process_lines = [
        line
        for line in processes["stdout"].splitlines()
        if train_match in line
        and "remote_food_rtdetr_monitor.sh" not in line
        and "food_rtdetr_stage3_monitor" not in line
    ]

    parsed = {
        "latest_progress": "",
        "epoch": None,
        "iteration": None,
        "total_iterations": None,
        "latest_test_progress": "",
        "test_iteration": None,
        "test_total_iterations": None,
        "failure_matches": [],
    }
    if train_log.exists():
        parsed = parse_train_log_text(
            train_log.read_text(encoding="utf-8", errors="replace"),
            failure_pattern=failure_pattern,
        )

    gpu = run_text(
        [
            "nvidia-smi",
            "--query-gpu=index,name,memory.used,memory.total,utilization.gpu,temperature.gpu,power.draw",
            "--format=csv,noheader",
        ]
    )
    disk = run_text(["df", "-h", str(work_root)])

    status_name = "running" if screen_name in screen["stdout"] and process_lines else "stopped"
    if parsed["failure_matches"]:
        status_name = "failure_pattern_seen"

    return {
        "timestamp": int(time.time()),
        "timestamp_local": time.strftime("%Y-%m-%d %H:%M:%S %Z"),
        "status": status_name,
        "screen_present": screen_name in screen["stdout"],
        "train_process_count": len(process_lines),
        "train_log": str(train_log),
        "latest_progress": parsed["latest_progress"],
        "epoch": parsed["epoch"],
        "iteration": parsed["iteration"],
        "total_iterations": parsed["total_iterations"],
        "latest_test_progress": parsed["latest_test_progress"],
        "test_iteration": parsed["test_iteration"],
        "test_total_iterations": parsed["test_total_iterations"],
        "failure_match_count": len(parsed["failure_matches"]),
        "failure_tail": parsed["failure_matches"][-5:],
        "gpu": gpu["stdout"],
        "disk": disk["stdout"],
    }


def write_status_once_from_env() -> dict[str, Any]:
    status_jsonl = Path(os.environ["STATUS_JSONL"])
    status = collect_status(
        screen_name=os.environ["SCREEN_NAME"],
        work_root=Path(os.environ["WORK_ROOT"]),
        train_log=Path(os.environ["TRAIN_LOG"]),
        train_match=os.environ["TRAIN_MATCH"],
        failure_pattern=os.environ["FAILURE_PATTERN"],
    )
    status_jsonl.parent.mkdir(parents=True, exist_ok=True)
    with status_jsonl.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(status, ensure_ascii=False) + "\n")
    return status


def main() -> None:
    print(json.dumps(write_status_once_from_env(), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
