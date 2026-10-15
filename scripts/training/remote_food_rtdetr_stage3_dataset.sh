#!/usr/bin/env bash
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-/root/miniconda3/bin/python}"
WORK_ROOT="${WORK_ROOT:-/root/autodl-tmp/food_rtdetr_stage3}"
EXTRA_NORMALIZED_ROOT="${EXTRA_NORMALIZED_ROOT:-${WORK_ROOT}/normalized}"
BASE_COCO_DATASET_ROOT="${BASE_COCO_DATASET_ROOT:-/root/autodl-tmp/food_rtdetr_v2_mask/research_full}"
BASE_NORMALIZED_JSONL="${BASE_NORMALIZED_JSONL:-${EXTRA_NORMALIZED_ROOT}/base_coco_existing.jsonl}"
MERGED_JSONL="${MERGED_JSONL:-${EXTRA_NORMALIZED_ROOT}/stage3_research_all.jsonl}"
DATASET_ROOT="${DATASET_ROOT:-${WORK_ROOT}/research_stage3_no_copy}"
BUILDER_SCRIPT="${BUILDER_SCRIPT:-/root/autodl-tmp/cal-repro/scripts/training/build_food_rtdetr_v1_dataset.py}"
LICENSE_POLICY="${LICENSE_POLICY:-research_full}"
COPY_IMAGES="${COPY_IMAGES:-0}"
SOURCE_COUNTS_CSV="${SOURCE_COUNTS_CSV:-${WORK_ROOT}/source_counts.csv}"

mkdir -p "${EXTRA_NORMALIZED_ROOT}" "${DATASET_ROOT}" "$(dirname "${SOURCE_COUNTS_CSV}")"

if [[ -n "${BASE_COCO_DATASET_ROOT}" && -d "${BASE_COCO_DATASET_ROOT}/annotations" ]]; then
  "${PYTHON_BIN}" "${BUILDER_SCRIPT}" convert-coco \
    --dataset-root "${BASE_COCO_DATASET_ROOT}" \
    --output-jsonl "${BASE_NORMALIZED_JSONL}"
fi

if [[ ! -s "${BASE_NORMALIZED_JSONL}" ]]; then
  echo "missing base normalized JSONL: ${BASE_NORMALIZED_JSONL}" >&2
  exit 1
fi

: > "${MERGED_JSONL}"
cat "${BASE_NORMALIZED_JSONL}" >> "${MERGED_JSONL}"
printf '\n' >> "${MERGED_JSONL}"
find "${EXTRA_NORMALIZED_ROOT}" -maxdepth 1 -type f -name '*.jsonl' \
  ! -name "$(basename "${MERGED_JSONL}")" \
  ! -name "$(basename "${BASE_NORMALIZED_JSONL}")" \
  ! -name 'all_available_bbox.jsonl' -print0 \
  | sort -z \
  | xargs -0 -I{} sh -c 'cat "$1" >> "$2"; printf "\n" >> "$2"' sh {} "${MERGED_JSONL}"
sed -i '/^[[:space:]]*$/d' "${MERGED_JSONL}"

"${PYTHON_BIN}" - <<PY
import csv
import json
from collections import Counter
from pathlib import Path

merged = Path("${MERGED_JSONL}")
out = Path("${SOURCE_COUNTS_CSV}")
counts = Counter()
bbox_types = Counter()
with merged.open(encoding="utf-8") as handle:
    for line in handle:
        row = json.loads(line)
        counts[str(row.get("source_dataset") or "Unknown")] += 1
        bbox_types[str(row.get("bbox_type") or "unknown")] += 1
out.parent.mkdir(parents=True, exist_ok=True)
with out.open("w", encoding="utf-8", newline="") as handle:
    writer = csv.writer(handle)
    writer.writerow(["kind", "name", "rows"])
    for name, rows in sorted(counts.items()):
        writer.writerow(["source_dataset", name, rows])
    for name, rows in sorted(bbox_types.items()):
        writer.writerow(["bbox_type", name, rows])
print(json.dumps({"merged_jsonl": str(merged), "rows": sum(counts.values()), "source_counts_csv": str(out)}, ensure_ascii=False))
PY

copy_args=()
if [[ "${COPY_IMAGES}" != "1" ]]; then
  copy_args+=(--no-copy-images)
fi

"${PYTHON_BIN}" "${BUILDER_SCRIPT}" build \
  --output-root "${DATASET_ROOT}" \
  --normalized-jsonl "${MERGED_JSONL}" \
  --license-policy "${LICENSE_POLICY}" \
  "${copy_args[@]}"
