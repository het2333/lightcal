#!/usr/bin/env python3
"""Resume the official Food-101 parquet shards from the HF mirror.

The raw mirror URLs can return tiny HTML/error pages for missing paths, so this
script lists the dataset repository first, checks expected shard sizes, and only
then downloads the real files through huggingface_hub.
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

from huggingface_hub import HfApi, hf_hub_download


ENDPOINT = os.environ.get("HF_ENDPOINT", "https://hf-mirror.com")
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
    try:
        entries = api.list_repo_tree(
            repo_id=REPO_ID,
            repo_type="dataset",
            path_in_repo="data",
            recursive=False,
        )
        files = []
        for entry in entries:
            path = getattr(entry, "path", "")
            size = getattr(entry, "size", None)
            if path.endswith(".parquet"):
                files.append((path, size))
        if files:
            return sorted(files)
    except TypeError:
        pass
    except Exception as exc:  # pragma: no cover - operational diagnostics.
        log(f"list_repo_tree failed, falling back to list_repo_files: {exc}")

    paths = api.list_repo_files(repo_id=REPO_ID, repo_type="dataset")
    return sorted((p, None) for p in paths if p.startswith("data/") and p.endswith(".parquet"))


def file_is_complete(path: Path, expected_size: int | None) -> bool:
    if not path.exists():
        return False
    size = path.stat().st_size
    if expected_size is not None:
        return size == expected_size
    return size >= MIN_VALID_BYTES


def main() -> int:
    os.environ["HF_ENDPOINT"] = ENDPOINT
    TARGET_ROOT.mkdir(parents=True, exist_ok=True)
    files = iter_data_files()
    if not files:
        log("No Food-101 parquet files found from repository metadata.")
        return 2

    log(f"Endpoint: {ENDPOINT}")
    log(f"Repository: {REPO_ID}")
    log(f"Target: {TARGET_ROOT}")
    log(f"Parquet shards: {len(files)}")

    for index, (path_in_repo, expected_size) in enumerate(files, start=1):
        local_path = TARGET_ROOT / path_in_repo
        current_size = local_path.stat().st_size if local_path.exists() else 0
        if file_is_complete(local_path, expected_size):
            log(f"[{index}/{len(files)}] skip complete {path_in_repo} ({current_size} bytes)")
            continue
        if local_path.exists():
            log(
                f"[{index}/{len(files)}] remove incomplete {path_in_repo} "
                f"({current_size} bytes, expected {expected_size or 'unknown'})"
            )
            local_path.unlink()

        for attempt in range(1, 6):
            try:
                log(f"[{index}/{len(files)}] download {path_in_repo}, attempt {attempt}")
                hf_hub_download(
                    repo_id=REPO_ID,
                    filename=path_in_repo,
                    repo_type="dataset",
                    endpoint=ENDPOINT,
                    local_dir=str(TARGET_ROOT),
                    resume_download=True,
                )
                break
            except Exception as exc:
                log(f"[{index}/{len(files)}] failed attempt {attempt}: {exc}")
                if attempt == 5:
                    raise
                time.sleep(20 * attempt)

        final_size = local_path.stat().st_size if local_path.exists() else 0
        if not file_is_complete(local_path, expected_size):
            log(
                f"[{index}/{len(files)}] still incomplete {path_in_repo}: "
                f"{final_size} bytes, expected {expected_size or 'unknown'}"
            )
            return 3
        log(f"[{index}/{len(files)}] complete {path_in_repo} ({final_size} bytes)")

    log("Food-101 official parquet download complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
