#!/usr/bin/env bash
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-/root/miniconda3/bin/python}"
WORK_ROOT="${WORK_ROOT:-/root/autodl-tmp/food_rtdetr_v1}"
RTDETR_ROOT="${RTDETR_ROOT:-/root/autodl-tmp/RT-DETR-main/rtdetrv2_pytorch}"
REPO_ZIP="${WORK_ROOT}/RT-DETR-main.zip"
RAW_ROOT="${WORK_ROOT}/raw_datasets"
NORMALIZED_ROOT="${WORK_ROOT}/normalized"
DATASET_ROOT="${DATASET_ROOT:-${WORK_ROOT}/research_full}"
CONFIG_ROOT="${WORK_ROOT}/configs"
LOG_ROOT="${WORK_ROOT}/logs"
CHECKPOINT_ROOT="${WORK_ROOT}/checkpoints"
EPOCHES="${EPOCHES:-150}"
SMOKE_EPOCHES="${SMOKE_EPOCHES:-2}"
BATCH_SIZE="${BATCH_SIZE:-8}"
INPUT_SIZE="${INPUT_SIZE:-800}"
NUM_WORKERS="${NUM_WORKERS:-4}"
LICENSE_POLICY="${LICENSE_POLICY:-research_full}"
MODEL_CONFIG_NAME="${MODEL_CONFIG_NAME:-rtdetrv2_r50vd_6x_coco}"
PRETRAINED_URL="${PRETRAINED_URL:-https://github.com/lyuwenyu/storage/releases/download/v0.1/rtdetrv2_r50vd_6x_coco_ema.pth}"
PRETRAINED_CKPT="${PRETRAINED_CKPT:-${CHECKPOINT_ROOT}/${MODEL_CONFIG_NAME}.pth}"
UECFOODPIX_URL="${UECFOODPIX_URL:-https://mm.cs.uec.ac.jp/uecfoodpix/UECFOODPIXCOMPLETE.tar}"
FOODSEG103_URL="${FOODSEG103_URL:-https://research.larc.smu.edu.sg/downloads/datarepo/FoodSeg103.zip}"
FOODSEG103_UNZIP_PASSWORD="${FOODSEG103_UNZIP_PASSWORD:-}"
COLLECT_FOOD101_OFFICIAL="${COLLECT_FOOD101_OFFICIAL:-0}"
FOOD101_OFFICIAL_URL="${FOOD101_OFFICIAL_URL:-http://data.vision.ee.ethz.ch/cvl/food-101.tar.gz}"
COLLECT_FOODX251="${COLLECT_FOODX251:-0}"
FOODX251_ANNOT_URL="${FOODX251_ANNOT_URL:-https://food-x.s3.amazonaws.com/annot.tar}"
FOODX251_TRAIN_URL="${FOODX251_TRAIN_URL:-https://food-x.s3.amazonaws.com/train.tar}"
FOODX251_VAL_URL="${FOODX251_VAL_URL:-https://food-x.s3.amazonaws.com/val.tar}"
CLASSIFICATION_DATASET_ROOTS="${CLASSIFICATION_DATASET_ROOTS:-}"
CLASSIFICATION_MAX_PER_CLASS="${CLASSIFICATION_MAX_PER_CLASS:-0}"
PSEUDO_BBOX_MARGIN_RATIO="${PSEUDO_BBOX_MARGIN_RATIO:-0.08}"
PSEUDO_BBOX_DEFAULT_CONFIDENCE="${PSEUDO_BBOX_DEFAULT_CONFIDENCE:-0.58}"
USE_MODEL_TUNING_CKPT="${USE_MODEL_TUNING_CKPT:-0}"
USE_BACKBONE_PRETRAINED="${USE_BACKBONE_PRETRAINED:-false}"
AUTO_START_FULL_AFTER_SMOKE="${AUTO_START_FULL_AFTER_SMOKE:-1}"
START_TRAIN="${START_TRAIN:-1}"
COPY_IMAGES="${COPY_IMAGES:-1}"
CHECKPOINT_FREQ="${CHECKPOINT_FREQ:-5}"
SMOKE_CHECKPOINT_FREQ="${SMOKE_CHECKPOINT_FREQ:-1}"
TRAIN_FAILURE_PATTERN="${TRAIN_FAILURE_PATTERN:-Traceback|CUDA out of memory|RuntimeError|Exception|Killed}"
BUILDER_SCRIPT="${BUILDER_SCRIPT:-/root/autodl-tmp/cal-repro/scripts/training/build_food_rtdetr_v1_dataset.py}"

mkdir -p "${WORK_ROOT}" "${RAW_ROOT}" "${NORMALIZED_ROOT}" "${DATASET_ROOT}" "${CONFIG_ROOT}" "${LOG_ROOT}" "${CHECKPOINT_ROOT}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

wait_for_existing_download() {
  local out="$1"
  local pids
  while pids="$(ps -eo pid=,args= | awk -v out="${out}" '$0 ~ /[w]get/ && index($0, "-O " out) {print $1}')" && [[ -n "${pids}" ]]; do
    log "已有下载进程正在写 ${out}: ${pids}；等待其结束。"
    sleep 60
  done
}

download_file() {
  local url="$1"
  local out="$2"
  if [[ -s "${out}" ]]; then
    if [[ "${out}" == *.zip ]] && ! unzip -tq "${out}" >/dev/null 2>&1; then
      log "检测到未完成或损坏的 zip，继续续传: ${out}"
    else
      log "已存在: ${out}"
      return 0
    fi
  fi
  wait_for_existing_download "${out}"
  if [[ -s "${out}" ]]; then
    if [[ "${out}" == *.zip ]] && ! unzip -tq "${out}" >/dev/null 2>&1; then
      log "已有下载结束但 zip 仍未完整，继续续传: ${out}"
    else
      log "已存在: ${out}"
      return 0
    fi
  fi
  log "下载: ${url}"
  if command -v wget >/dev/null 2>&1; then
    wget -c --tries=5 --timeout=30 -O "${out}" "${url}"
  else
    curl -L --retry 5 --connect-timeout 30 -o "${out}" "${url}"
  fi
}

download_first_available() {
  local out="$1"
  shift
  local url
  for url in "$@"; do
    if download_file "${url}" "${out}"; then
      return 0
    fi
    rm -f "${out}"
  done
  return 1
}

bootstrap_rtdetr() {
  if [[ -f "${RTDETR_ROOT}/tools/train.py" ]]; then
    log "RT-DETRv2 已存在: ${RTDETR_ROOT}"
  else
    log "准备 RT-DETRv2 官方代码"
    rm -rf /root/autodl-tmp/RT-DETR-main /root/autodl-tmp/RT-DETR-main.tmp
    download_file "https://codeload.github.com/lyuwenyu/RT-DETR/zip/refs/heads/main" "${REPO_ZIP}"
    unzip -q "${REPO_ZIP}" -d /root/autodl-tmp
  fi
  if [[ ! -f "${RTDETR_ROOT}/tools/train.py" ]]; then
    log "未找到 ${RTDETR_ROOT}/tools/train.py"
    exit 1
  fi
  log "安装 RT-DETRv2 Python 依赖"
  "${PYTHON_BIN}" -m pip install -q --upgrade pip
  "${PYTHON_BIN}" -m pip install -q -r "${RTDETR_ROOT}/requirements.txt"
}

find_dataset_root() {
  local base="$1"
  find "${base}" -maxdepth 3 -type f -name category.txt -print -quit | xargs -r dirname
}

find_foodseg_root() {
  local base="$1"
  local found
  found="$(find "${base}" -type d -path '*/Images/ann_dir' -print -quit || true)"
  if [[ -n "${found}" ]]; then
    dirname "$(dirname "${found}")"
    return 0
  fi
  found="$(find "${base}" -type d -name ann_dir -print -quit || true)"
  if [[ -n "${found}" ]]; then
    dirname "${found}"
    return 0
  fi
  found="$(find "${base}" -type d -name masks -print -quit || true)"
  if [[ -n "${found}" ]]; then
    dirname "${found}"
    return 0
  fi
  return 1
}

collect_uecfood() {
  local report="${WORK_ROOT}/collection_report.jsonl"
  : > "${report}"
  for spec in \
    "UECFOOD-100|dataset100.zip" \
    "UECFOOD-256|dataset256.zip"; do
    IFS='|' read -r source_name archive_name <<< "${spec}"
    local archive="${RAW_ROOT}/${archive_name}"
    local extract_dir="${RAW_ROOT}/${source_name}"
    if download_first_available "${archive}" \
      "https://hf-mirror.com/datasets/kng-research/uecfood256/resolve/main/${archive_name}" \
      "https://huggingface.co/datasets/kng-research/uecfood256/resolve/main/${archive_name}" \
      "https://huggingface.co/datasets/tiennv/uecfood256/resolve/main/${archive_name}" \
      "http://foodcam.mobi/${archive_name}"; then
      mkdir -p "${extract_dir}"
      if [[ ! -f "${extract_dir}/.unzipped" ]]; then
        log "解压 ${source_name}"
        unzip -q -o "${archive}" -d "${extract_dir}"
        touch "${extract_dir}/.unzipped"
      fi
      local dataset_dir
      dataset_dir="$(find_dataset_root "${extract_dir}" || true)"
      if [[ -n "${dataset_dir}" ]]; then
        local output_jsonl="${NORMALIZED_ROOT}/${source_name}.jsonl"
        log "转换 ${source_name} -> normalized JSONL"
        "${PYTHON_BIN}" "${BUILDER_SCRIPT}" convert-uec \
          --dataset-root "${dataset_dir}" \
          --output-jsonl "${output_jsonl}" \
          --source-dataset "${source_name}"
        printf '{"source_dataset":"%s","status":"converted","normalized_jsonl":"%s"}\n' "${source_name}" "${output_jsonl}" >> "${report}"
      else
        printf '{"source_dataset":"%s","status":"missing_category_txt"}\n' "${source_name}" >> "${report}"
      fi
    else
      printf '{"source_dataset":"%s","status":"download_failed"}\n' "${source_name}" >> "${report}"
    fi
  done
}

collect_uecfoodpix() {
  local report="${WORK_ROOT}/collection_report.jsonl"
  local source_name="UECFoodPixComplete"
  local archive="${RAW_ROOT}/UECFOODPIXCOMPLETE.tar"
  local extract_dir="${RAW_ROOT}/${source_name}"
  if download_first_available "${archive}" "${UECFOODPIX_URL}"; then
    mkdir -p "${extract_dir}"
    if [[ ! -f "${extract_dir}/.untarred" ]]; then
      log "解压 ${source_name}"
      tar -xf "${archive}" -C "${extract_dir}"
      touch "${extract_dir}/.untarred"
    fi
    local dataset_dir
    dataset_dir="$(find_dataset_root "${extract_dir}" || true)"
    if [[ -n "${dataset_dir}" ]]; then
      local output_jsonl="${NORMALIZED_ROOT}/${source_name}.jsonl"
      log "转换 ${source_name} mask -> normalized JSONL"
      "${PYTHON_BIN}" "${BUILDER_SCRIPT}" convert-uecfoodpix \
        --dataset-root "${dataset_dir}" \
        --output-jsonl "${output_jsonl}" \
        --source-dataset "${source_name}"
      printf '{"source_dataset":"%s","status":"converted","normalized_jsonl":"%s"}\n' "${source_name}" "${output_jsonl}" >> "${report}"
    else
      printf '{"source_dataset":"%s","status":"missing_category_txt"}\n' "${source_name}" >> "${report}"
    fi
  else
    printf '{"source_dataset":"%s","status":"download_failed"}\n' "${source_name}" >> "${report}"
  fi
}

collect_foodseg103() {
  local report="${WORK_ROOT}/collection_report.jsonl"
  local source_name="FoodSeg103"
  local archive="${RAW_ROOT}/FoodSeg103.zip"
  local extract_dir="${RAW_ROOT}/${source_name}"
  if download_first_available "${archive}" "${FOODSEG103_URL}"; then
    mkdir -p "${extract_dir}"
    if [[ ! -f "${extract_dir}/.unzipped" ]]; then
      log "解压 ${source_name}"
      if [[ -n "${FOODSEG103_UNZIP_PASSWORD}" ]]; then
        if ! unzip -P "${FOODSEG103_UNZIP_PASSWORD}" -q -o "${archive}" -d "${extract_dir}"; then
          printf '{"source_dataset":"%s","status":"extract_failed"}\n' "${source_name}" >> "${report}"
          return 0
        fi
      else
        if ! unzip -q -o "${archive}" -d "${extract_dir}"; then
          printf '{"source_dataset":"%s","status":"extract_failed"}\n' "${source_name}" >> "${report}"
          return 0
        fi
      fi
      touch "${extract_dir}/.unzipped"
    fi
    local dataset_dir
    dataset_dir="$(find_foodseg_root "${extract_dir}" || true)"
    if [[ -n "${dataset_dir}" ]]; then
      local output_jsonl="${NORMALIZED_ROOT}/${source_name}.jsonl"
      log "转换 ${source_name} semantic mask -> normalized JSONL"
      "${PYTHON_BIN}" "${BUILDER_SCRIPT}" convert-foodseg \
        --dataset-root "${dataset_dir}" \
        --output-jsonl "${output_jsonl}" \
        --source-dataset "${source_name}"
      printf '{"source_dataset":"%s","status":"converted","normalized_jsonl":"%s"}\n' "${source_name}" "${output_jsonl}" >> "${report}"
    else
      printf '{"source_dataset":"%s","status":"missing_foodseg_layout"}\n' "${source_name}" >> "${report}"
    fi
  else
    printf '{"source_dataset":"%s","status":"download_failed"}\n' "${source_name}" >> "${report}"
  fi
}

collect_food101_official() {
  if [[ "${COLLECT_FOOD101_OFFICIAL}" != "1" ]]; then
    return 0
  fi
  local report="${WORK_ROOT}/collection_report.jsonl"
  local source_name="Food-101"
  local archive="${RAW_ROOT}/Food-101/food-101.tar.gz"
  local extract_dir="${RAW_ROOT}/Food-101"
  local dataset_dir="${extract_dir}/food-101"
  if download_first_available "${archive}" "${FOOD101_OFFICIAL_URL}"; then
    mkdir -p "${extract_dir}"
    if [[ ! -d "${dataset_dir}/images" ]]; then
      log "解压 ${source_name}"
      if ! tar -xzf "${archive}" -C "${extract_dir}"; then
        printf '{"source_dataset":"%s","status":"extract_failed"}\n' "${source_name}" >> "${report}"
        return 0
      fi
    fi
    if [[ -d "${dataset_dir}/images" ]]; then
      local output_jsonl="${NORMALIZED_ROOT}/Food-101_pseudo_single_label.jsonl"
      log "转换 ${source_name} 官方分类数据 -> pseudo bbox normalized JSONL"
      "${PYTHON_BIN}" "${BUILDER_SCRIPT}" convert-class-dir \
        --dataset-root "${dataset_dir}" \
        --output-jsonl "${output_jsonl}" \
        --source-dataset "${source_name}" \
        --bbox-margin-ratio "${PSEUDO_BBOX_MARGIN_RATIO}" \
        --default-confidence "${PSEUDO_BBOX_DEFAULT_CONFIDENCE}" \
        --max-per-class "${CLASSIFICATION_MAX_PER_CLASS}"
      printf '{"source_dataset":"%s","status":"converted","normalized_jsonl":"%s","bbox_type":"pseudo_single_label"}\n' "${source_name}" "${output_jsonl}" >> "${report}"
    else
      printf '{"source_dataset":"%s","status":"missing_food101_images"}\n' "${source_name}" >> "${report}"
    fi
  else
    printf '{"source_dataset":"%s","status":"download_failed"}\n' "${source_name}" >> "${report}"
  fi
}

collect_foodx251() {
  if [[ "${COLLECT_FOODX251}" != "1" ]]; then
    return 0
  fi
  local report="${WORK_ROOT}/collection_report.jsonl"
  local source_name="FoodX-251"
  local extract_dir="${RAW_ROOT}/FoodX-251"
  local annot_archive="${extract_dir}/annot.tar"
  local train_archive="${extract_dir}/train.tar"
  local val_archive="${extract_dir}/val.tar"
  local annot_dir="${extract_dir}/annot"
  local train_dir="${extract_dir}/train"
  local val_dir="${extract_dir}/val"
  mkdir -p "${extract_dir}" "${annot_dir}" "${train_dir}" "${val_dir}"
  if ! download_first_available "${annot_archive}" "${FOODX251_ANNOT_URL}"; then
    printf '{"source_dataset":"%s","status":"annot_download_failed"}\n' "${source_name}" >> "${report}"
    return 0
  fi
  if ! download_first_available "${train_archive}" "${FOODX251_TRAIN_URL}"; then
    printf '{"source_dataset":"%s","status":"train_download_failed"}\n' "${source_name}" >> "${report}"
    return 0
  fi
  if ! download_first_available "${val_archive}" "${FOODX251_VAL_URL}"; then
    printf '{"source_dataset":"%s","status":"val_download_failed"}\n' "${source_name}" >> "${report}"
    return 0
  fi
  if [[ ! -f "${annot_dir}/class_list.txt" ]]; then
    tar -xf "${annot_archive}" -C "${annot_dir}"
  fi
  if ! classification_dir_has_images "${train_dir}"; then
    tar -xf "${train_archive}" -C "${train_dir}"
  fi
  if ! classification_dir_has_images "${val_dir}"; then
    tar -xf "${val_archive}" -C "${val_dir}"
  fi
  if [[ -f "${annot_dir}/class_list.txt" && -f "${annot_dir}/train_info.csv" ]]; then
    log "转换 ${source_name} train CSV -> pseudo bbox normalized JSONL"
    "${PYTHON_BIN}" "${BUILDER_SCRIPT}" convert-class-csv \
      --image-root "${train_dir}" \
      --labels-csv "${annot_dir}/train_info.csv" \
      --class-list "${annot_dir}/class_list.txt" \
      --output-jsonl "${NORMALIZED_ROOT}/FoodX-251_train_pseudo_single_label.jsonl" \
      --source-dataset "${source_name}" \
      --split train \
      --bbox-margin-ratio "${PSEUDO_BBOX_MARGIN_RATIO}" \
      --default-confidence "${PSEUDO_BBOX_DEFAULT_CONFIDENCE}"
  fi
  if [[ -f "${annot_dir}/class_list.txt" && -f "${annot_dir}/val_info.csv" ]]; then
    log "转换 ${source_name} val CSV -> pseudo bbox normalized JSONL"
    "${PYTHON_BIN}" "${BUILDER_SCRIPT}" convert-class-csv \
      --image-root "${val_dir}" \
      --labels-csv "${annot_dir}/val_info.csv" \
      --class-list "${annot_dir}/class_list.txt" \
      --output-jsonl "${NORMALIZED_ROOT}/FoodX-251_val_pseudo_single_label.jsonl" \
      --source-dataset "${source_name}" \
      --split val \
      --bbox-margin-ratio "${PSEUDO_BBOX_MARGIN_RATIO}" \
      --default-confidence "${PSEUDO_BBOX_DEFAULT_CONFIDENCE}"
  fi
  printf '{"source_dataset":"%s","status":"converted","bbox_type":"pseudo_single_label"}\n' "${source_name}" >> "${report}"
}

safe_dataset_name() {
  printf '%s' "$1" | tr ' /' '__' | tr -cd 'A-Za-z0-9_.-'
}

classification_dir_has_images() {
  local dataset_dir="$1"
  [[ -n "$(find "${dataset_dir}" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.bmp' \) -print -quit 2>/dev/null || true)" ]]
}

collect_existing_classification_dirs() {
  local report="${WORK_ROOT}/collection_report.jsonl"
  local specs=()
  if [[ -n "${CLASSIFICATION_DATASET_ROOTS}" ]]; then
    IFS=';' read -r -a specs <<< "${CLASSIFICATION_DATASET_ROOTS}"
  else
    specs=(
      "ChineseFoodNet|${RAW_ROOT}/ChineseFoodNet|${CLASSIFICATION_MAX_PER_CLASS}"
      "VireoFood-172|${RAW_ROOT}/VireoFood-172|${CLASSIFICATION_MAX_PER_CLASS}"
      "Food2K|${RAW_ROOT}/Food2K|${CLASSIFICATION_MAX_PER_CLASS}"
      "ISIA Food-500|${RAW_ROOT}/ISIAFood500|${CLASSIFICATION_MAX_PER_CLASS}"
      "FoodX-251|${RAW_ROOT}/FoodX-251|${CLASSIFICATION_MAX_PER_CLASS}"
      "Food-101|${RAW_ROOT}/Food-101/food-101|${CLASSIFICATION_MAX_PER_CLASS}"
    )
  fi
  local spec
  for spec in "${specs[@]}"; do
    [[ -n "${spec}" ]] || continue
    IFS='|' read -r source_name dataset_dir max_per_class <<< "${spec}"
    if [[ -z "${source_name}" || -z "${dataset_dir}" ]]; then
      continue
    fi
    if [[ ! -d "${dataset_dir}" ]]; then
      printf '{"source_dataset":"%s","status":"classification_dir_missing","dataset_root":"%s"}\n' "${source_name}" "${dataset_dir}" >> "${report}"
      continue
    fi
    if ! classification_dir_has_images "${dataset_dir}"; then
      printf '{"source_dataset":"%s","status":"classification_dir_no_images","dataset_root":"%s"}\n' "${source_name}" "${dataset_dir}" >> "${report}"
      continue
    fi
    local safe_name
    local output_jsonl
    safe_name="$(safe_dataset_name "${source_name}")"
    output_jsonl="${NORMALIZED_ROOT}/${safe_name}_pseudo_single_label.jsonl"
    log "转换分类目录 ${source_name} -> pseudo bbox normalized JSONL"
    "${PYTHON_BIN}" "${BUILDER_SCRIPT}" convert-class-dir \
      --dataset-root "${dataset_dir}" \
      --output-jsonl "${output_jsonl}" \
      --source-dataset "${source_name}" \
      --bbox-margin-ratio "${PSEUDO_BBOX_MARGIN_RATIO}" \
      --default-confidence "${PSEUDO_BBOX_DEFAULT_CONFIDENCE}" \
      --max-per-class "${max_per_class:-${CLASSIFICATION_MAX_PER_CLASS}}"
    printf '{"source_dataset":"%s","status":"converted","normalized_jsonl":"%s","bbox_type":"pseudo_single_label"}\n' "${source_name}" "${output_jsonl}" >> "${report}"
  done
}

merge_normalized_jsonl() {
  local merged="${NORMALIZED_ROOT}/all_available_bbox.jsonl"
  : > "${merged}"
  find "${NORMALIZED_ROOT}" -maxdepth 1 -type f -name '*.jsonl' ! -name 'all_available_bbox.jsonl' -print0 \
    | sort -z \
    | xargs -0 -I{} sh -c 'cat "$1" >> "$2"; printf "\n" >> "$2"' sh {} "${merged}"
  sed -i '/^[[:space:]]*$/d' "${merged}"
  printf '%s\n' "${merged}"
}

build_coco_dataset() {
  local merged_jsonl="$1"
  local copy_args=()
  if [[ "${COPY_IMAGES}" != "1" ]]; then
    copy_args+=(--no-copy-images)
  fi
  log "生成 COCO 数据集: ${DATASET_ROOT}"
  "${PYTHON_BIN}" "${BUILDER_SCRIPT}" build \
    --output-root "${DATASET_ROOT}" \
    --normalized-jsonl "${merged_jsonl}" \
    --license-policy "${LICENSE_POLICY}" \
    "${copy_args[@]}"
}

class_count() {
  "${PYTHON_BIN}" - <<PY
import csv
from pathlib import Path
path = Path("${DATASET_ROOT}") / "meta" / "class_map_v1.csv"
with path.open(encoding="utf-8") as f:
    ids = [int(row["category_id"]) for row in csv.DictReader(f)]
print(max(ids) + 1)
PY
}

write_train_config() {
  local config_path="$1"
  local epoches="$2"
  local checkpoint_freq="${3:-${CHECKPOINT_FREQ}}"
  local classes
  local stop_epoch
  classes="$(class_count)"
  if (( epoches > 10 )); then
    stop_epoch=$((epoches - 5))
  else
    stop_epoch="${epoches}"
  fi
  cat > "${config_path}" <<YAML
__include__: [
  '${RTDETR_ROOT}/configs/rtdetrv2/${MODEL_CONFIG_NAME}.yml',
]

num_classes: ${classes}
remap_mscoco_category: False
eval_spatial_size: [${INPUT_SIZE}, ${INPUT_SIZE}]
epoches: ${epoches}
output_dir: ${WORK_ROOT}/output/${MODEL_CONFIG_NAME}_food_${INPUT_SIZE}px_${epoches}e
print_freq: 20
checkpoint_freq: ${checkpoint_freq}

train_dataloader:
  dataset:
    img_folder: ${DATASET_ROOT}
    ann_file: ${DATASET_ROOT}/annotations/train.json
    return_masks: False
    transforms:
      ops:
        - {type: RandomPhotometricDistort, p: 0.5}
        - {type: RandomZoomOut, fill: 0}
        - {type: RandomIoUCrop, p: 0.8}
        - {type: SanitizeBoundingBoxes, min_size: 1}
        - {type: RandomHorizontalFlip}
        - {type: Resize, size: [${INPUT_SIZE}, ${INPUT_SIZE}]}
        - {type: SanitizeBoundingBoxes, min_size: 1}
        - {type: ConvertPILImage, dtype: 'float32', scale: True}
        - {type: ConvertBoxes, fmt: 'cxcywh', normalize: True}
      policy:
        name: stop_epoch
        epoch: ${stop_epoch}
        ops: ['RandomPhotometricDistort', 'RandomZoomOut', 'RandomIoUCrop']
  total_batch_size: ${BATCH_SIZE}
  num_workers: ${NUM_WORKERS}
  collate_fn:
    type: BatchImageCollateFunction
    scales: [640, 672, 704, 736, 768, ${INPUT_SIZE}, 832, 864, 896, 928, 960, 1024]
    stop_epoch: ${stop_epoch}

val_dataloader:
  dataset:
    img_folder: ${DATASET_ROOT}
    ann_file: ${DATASET_ROOT}/annotations/val.json
    return_masks: False
    transforms:
      ops:
        - {type: Resize, size: [${INPUT_SIZE}, ${INPUT_SIZE}]}
        - {type: ConvertPILImage, dtype: 'float32', scale: True}
  total_batch_size: ${BATCH_SIZE}
  num_workers: ${NUM_WORKERS}
  collate_fn:
    type: BatchImageCollateFunction

PResNet:
  pretrained: ${USE_BACKBONE_PRETRAINED}
YAML
  log "写入配置: ${config_path}"
}

download_checkpoint() {
  download_file "${PRETRAINED_URL}" "${PRETRAINED_CKPT}"
}

start_screen_train() {
  local session_name="$1"
  local config_path="$2"
  local log_path="$3"
  local extra_note="$4"
  if screen -list | grep -q "[.]${session_name}[[:space:]]"; then
    log "screen 已存在: ${session_name}"
    return 0
  fi
  log "启动 screen 训练: ${session_name} (${extra_note})"
  local tuning_args=""
  if [[ "${USE_MODEL_TUNING_CKPT}" == "1" ]]; then
    tuning_args="-t '${PRETRAINED_CKPT}'"
  fi
  screen -dmS "${session_name}" bash -lc "cd '${RTDETR_ROOT}' && CUDA_VISIBLE_DEVICES=0 '${PYTHON_BIN}' tools/train.py -c '${config_path}' ${tuning_args} --use-amp --seed=0 > '${log_path}' 2>&1"
}

start_full_watcher() {
  if [[ "${AUTO_START_FULL_AFTER_SMOKE}" != "1" ]]; then
    return 0
  fi
  if screen -list | grep -q "[.]food_rtdetr_full_watcher[[:space:]]"; then
    log "full watcher 已存在"
    return 0
  fi
  log "启动 full watcher：全量 smoke 成功后自动启动正式训练"
  screen -dmS food_rtdetr_full_watcher bash -lc "while screen -list | grep -q '[.]food_rtdetr_smoke[[:space:]]'; do sleep 60; done; if grep -Eq '${TRAIN_FAILURE_PATTERN}' '${LOG_ROOT}/smoke_train.log'; then echo 'smoke failed, skip full train' >> '${LOG_ROOT}/full_watcher.log'; exit 1; fi; echo \"\$(date '+%F %T') smoke finished, starting full train\" >> '${LOG_ROOT}/full_watcher.log'; '${WORK_ROOT}/START_FULL_TRAIN_AFTER_SMOKE.sh' >> '${LOG_ROOT}/full_watcher.log' 2>&1"
}

main() {
  if [[ ! -f "${BUILDER_SCRIPT}" ]]; then
    log "缺少 builder: ${BUILDER_SCRIPT}"
    exit 1
  fi
  bootstrap_rtdetr
  collect_uecfood
  collect_uecfoodpix
  collect_foodseg103
  collect_food101_official
  collect_foodx251
  collect_existing_classification_dirs
  local merged_jsonl
  merged_jsonl="$(merge_normalized_jsonl)"
  if [[ ! -s "${merged_jsonl}" ]]; then
    log "没有可训练 bbox 数据，停止。"
    exit 1
  fi
  build_coco_dataset "${merged_jsonl}"
  if [[ "${USE_MODEL_TUNING_CKPT}" == "1" ]]; then
    download_checkpoint
  else
    log "跳过 RT-DETR 整模型预训练权重下载；如需微调，设置 USE_MODEL_TUNING_CKPT=1。"
  fi
  write_train_config "${CONFIG_ROOT}/food_rtdetrv1_smoke.yml" "${SMOKE_EPOCHES}" "${SMOKE_CHECKPOINT_FREQ}"
  write_train_config "${CONFIG_ROOT}/food_rtdetrv1_full.yml" "${EPOCHES}" "${CHECKPOINT_FREQ}"
  cat > "${WORK_ROOT}/START_FULL_TRAIN_AFTER_SMOKE.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
TUNING_ARGS=""
if [[ "${USE_MODEL_TUNING_CKPT}" == "1" ]]; then
  TUNING_ARGS="-t '${PRETRAINED_CKPT}'"
fi
screen -dmS food_rtdetr_train bash -lc "cd '${RTDETR_ROOT}' && CUDA_VISIBLE_DEVICES=0 '${PYTHON_BIN}' tools/train.py -c '${CONFIG_ROOT}/food_rtdetrv1_full.yml' \${TUNING_ARGS} --use-amp --seed=0 > '${LOG_ROOT}/full_train.log' 2>&1"
SH
  chmod +x "${WORK_ROOT}/START_FULL_TRAIN_AFTER_SMOKE.sh"
  if [[ "${START_TRAIN}" != "1" ]]; then
    log "START_TRAIN=${START_TRAIN}，仅完成数据准备和配置生成，不启动训练。"
    screen -list || true
    return 0
  fi
  start_screen_train "food_rtdetr_smoke" "${CONFIG_ROOT}/food_rtdetrv1_smoke.yml" "${LOG_ROOT}/smoke_train.log" "先跑 ${SMOKE_EPOCHES} epoch 验证环境"
  log "准备完成。smoke 通过后执行: ${WORK_ROOT}/START_FULL_TRAIN_AFTER_SMOKE.sh"
  start_full_watcher
  screen -list || true
}

if [[ "${FOOD_RTDETR_SOURCE_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
