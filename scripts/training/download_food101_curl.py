#!/usr/bin/env python3
"""Download official Food-101 parquet shards with size-checked curl retries."""

from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import quote

from huggingface_hub import HfApi


ENDPOINT = os.environ.get("HF_ENDPOINT", "https://hf-mirror.com").rstrip("/")
REPO_ID = os.environ.get("FOOD101_REPO_ID", "ethz/food101")
TARGET_ROOT = Path(
    os.environ.get(
        "FOOD101_TARGET_ROOT",
        "/root/autodl-tmp/glm_food_r1_experiment/official_data/Food-101",
    )
)
MIN_VALID_BYTES = 1_000_000


def log(message: str) -> None:
    print(message, flush=True)


def iter_data_files() -> list[tuple[str, int | None]]:
    api = HfApi(endpoint=ENDPOINT)
    entries = api.list_repo_tree(
        repo_id=REPO_ID,
        repo_type="dataset",
        path_in_repo="data",
        recursive=False,
    )
    files: list[tuple[str, int | None]] = []
    for entry in entries:
        path = getattr(entry, "path", "")
        size = getattr(entry, "size", None)
        if path.endswith(".parquet"):
            files.append((path, size))
    return sorted(files)


def is_complete(path: Path, expected_size: int | None) -> bool:
    if not path.exists():
        return False
    size = path.stat().st_size
    if expected_size is not None:
        return size == expected_size
    return size >= MIN_VALID_BYTES


def make_url(path_in_repo: str) -> str:
    repo_path = quote(REPO_ID, safe="/")
    file_path = quote(path_in_repo, safe="/")
    return f"{ENDPOINT}/datasets/{repo_path}/resolve/main/{file_path}"


def curl_download(url: str, part_path: Path) -> None:
    part_path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "curl",
            "--fail",
            "--location",
            "--continue-at",
            "-",
            "--retry",
            "8",
            "--retry-delay",
            "8",
            "--connect-timeout",
            "30",
            "--speed-time",
            "90",
            "--speed-limit",
            "4096",
            "--output",
            str(part_path),
            url,
        ],
        check=True,
    )


def main() -> int:
    TARGET_ROOT.mkdir(parents=True, exist_ok=True)
    files = iter_data_files()
    if not files:
        log("No Food-101 parquet shards found.")
        return 2

    log(f"Endpoint: {ENDPOINT}")
    log(f"Repository: {REPO_ID}")
    log(f"Target: {TARGET_ROOT}")
    log(f"Parquet shards: {len(files)}")

    for index, (path_in_repo, expected_size) in enumerate(files, start=1):
        final_path = TARGET_ROOT / path_in_repo
        part_path = final_path.with_suffix(final_path.suffix + ".part")
        current_size = final_path.stat().st_size if final_path.exists() else 0

        if is_complete(final_path, expected_size):
            log(f"[{index}/{len(files)}] skip complete {path_in_repo} ({current_size} bytes)")
            continue

        if final_path.exists() and current_size >= MIN_VALID_BYTES:
            if part_path.exists():
                part_path.unlink()
            log(f"[{index}/{len(files)}] move incomplete final to part: {current_size} bytes")
            final_path.rename(part_path)
        elif final_path.exists():
            log(f"[{index}/{len(files)}] remove tiny bad file: {current_size} bytes")
            final_path.unlink()

        if part_path.exists() and expected_size is not None and part_path.stat().st_size > expected_size:
            log(f"[{index}/{len(files)}] remove oversized part: {part_path.stat().st_size} bytes")
            part_path.unlink()

        url = make_url(path_in_repo)
        for attempt in range(1, 12):
            before = part_path.stat().st_size if part_path.exists() else 0
            log(
                f"[{index}/{len(files)}] curl {path_in_repo}, attempt {attempt}, "
                f"current {before}, expected {expected_size or 'unknown'}"
            )
            try:
                curl_download(url, part_path)
            except subprocess.CalledProcessError as exc:
                after = part_path.stat().st_size if part_path.exists() else 0
                log(f"[{index}/{len(files)}] curl failed rc={exc.returncode}, size {before}->{after}")
                if attempt == 11:
                    return exc.returncode
                time.sleep(10 * attempt)
                continue

            after = part_path.stat().st_size if part_path.exists() else 0
            if expected_size is None:
                if after >= MIN_VALID_BYTES:
                    break
            elif after == expected_size:
                break
            elif after > expected_size:
                log(f"[{index}/{len(files)}] part oversized {after}; deleting")
                part_path.unlink()
            else:
                log(f"[{index}/{len(files)}] partial after attempt: {after}/{expected_size}")
                time.sleep(5)
        else:
            return 4

        final_size = part_path.stat().st_size if part_path.exists() else 0
        if expected_size is not None and final_size != expected_size:
            log(f"[{index}/{len(files)}] incomplete after retries: {final_size}/{expected_size}")
            return 5
        part_path.rename(final_path)
        log(f"[{index}/{len(files)}] complete {path_in_repo} ({final_path.stat().st_size} bytes)")

    log("Food-101 official parquet download complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
