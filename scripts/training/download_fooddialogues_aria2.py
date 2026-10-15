#!/usr/bin/env python3
"""Download the official FoodDialogues dataset with aria2 and size checks."""

from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import quote

from huggingface_hub import HfApi


ENDPOINT = os.environ.get("HF_ENDPOINT", "https://hf-mirror.com").rstrip("/")
REPO_ID = os.environ.get("FOODDIALOGUES_REPO_ID", "Yueha0/FoodDialogues")
TARGET_ROOT = Path(
    os.environ.get(
        "FOODDIALOGUES_TARGET_ROOT",
        "/root/autodl-tmp/glm_food_r1_experiment/official_data/FoodDialogues",
    )
)
DOWNLOAD_LIMIT = os.environ.get("FOODDIALOGUES_DOWNLOAD_LIMIT", "25M")


def log(message: str) -> None:
    print(message, flush=True)


def iter_files() -> list[tuple[str, int | None]]:
    api = HfApi(endpoint=ENDPOINT)
    entries = api.list_repo_tree(repo_id=REPO_ID, repo_type="dataset", recursive=True)
    files: list[tuple[str, int | None]] = []
    for entry in entries:
        path = getattr(entry, "path", "")
        size = getattr(entry, "size", None)
        if path:
            files.append((path, size))
    return sorted(files)


def is_complete(path: Path, expected_size: int | None) -> bool:
    return path.exists() and (expected_size is None or path.stat().st_size == expected_size)


def make_url(path_in_repo: str) -> str:
    return (
        f"{ENDPOINT}/datasets/{quote(REPO_ID, safe='/')}"
        f"/resolve/main/{quote(path_in_repo, safe='/')}"
    )


def aria2_download(url: str, part_path: Path) -> None:
    part_path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "aria2c",
            "--continue=true",
            "--allow-overwrite=true",
            "--auto-file-renaming=false",
            "--file-allocation=none",
            "--max-connection-per-server=16",
            "--split=16",
            "--min-split-size=4M",
            "--max-tries=12",
            "--retry-wait=10",
            "--timeout=90",
            "--connect-timeout=30",
            "--summary-interval=30",
            f"--max-overall-download-limit={DOWNLOAD_LIMIT}",
            "--dir",
            str(part_path.parent),
            "--out",
            part_path.name,
            url,
        ],
        check=True,
    )


def main() -> int:
    TARGET_ROOT.mkdir(parents=True, exist_ok=True)
    files = iter_files()
    log(f"Endpoint: {ENDPOINT}")
    log(f"Repository: {REPO_ID}")
    log(f"Target: {TARGET_ROOT}")
    log(f"Files: {len(files)}")
    log(f"Limit: {DOWNLOAD_LIMIT}/s")

    for index, (path_in_repo, expected_size) in enumerate(files, start=1):
        final_path = TARGET_ROOT / path_in_repo
        part_path = final_path.with_suffix(final_path.suffix + ".part")
        aria_state = Path(str(part_path) + ".aria2")
        current_size = final_path.stat().st_size if final_path.exists() else 0

        if is_complete(final_path, expected_size):
            log(f"[{index}/{len(files)}] skip complete {path_in_repo} ({current_size} bytes)")
            continue

        if final_path.exists():
            if part_path.exists():
                part_path.unlink()
            if aria_state.exists():
                aria_state.unlink()
            log(f"[{index}/{len(files)}] move incomplete final to part: {current_size} bytes")
            final_path.rename(part_path)

        if part_path.exists() and expected_size is not None and part_path.stat().st_size > expected_size:
            log(f"[{index}/{len(files)}] remove oversized part: {part_path.stat().st_size} bytes")
            part_path.unlink()
            if aria_state.exists():
                aria_state.unlink()

        url = make_url(path_in_repo)
        for attempt in range(1, 10):
            before = part_path.stat().st_size if part_path.exists() else 0
            log(
                f"[{index}/{len(files)}] aria2 {path_in_repo}, attempt {attempt}, "
                f"current {before}, expected {expected_size or 'unknown'}"
            )
            try:
                aria2_download(url, part_path)
            except subprocess.CalledProcessError as exc:
                after = part_path.stat().st_size if part_path.exists() else 0
                log(f"[{index}/{len(files)}] aria2 failed rc={exc.returncode}, size {before}->{after}")
                if attempt == 9:
                    return exc.returncode
                time.sleep(15 * attempt)
                continue

            final_size = part_path.stat().st_size if part_path.exists() else 0
            if expected_size is None or final_size == expected_size:
                break
            log(f"[{index}/{len(files)}] partial after aria2: {final_size}/{expected_size}")
            time.sleep(10)
        else:
            return 4

        final_size = part_path.stat().st_size if part_path.exists() else 0
        if expected_size is not None and final_size != expected_size:
            log(f"[{index}/{len(files)}] incomplete after retries: {final_size}/{expected_size}")
            return 5
        if aria_state.exists():
            aria_state.unlink()
        part_path.rename(final_path)
        log(f"[{index}/{len(files)}] complete {path_in_repo} ({final_path.stat().st_size} bytes)")

    log("FoodDialogues official dataset download complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
