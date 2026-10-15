import csv
import json
from pathlib import Path

from PIL import Image


def test_maps_aliases_to_canonical_food_classes() -> None:
    from scripts.training.build_food_rtdetr_v1_dataset import map_label

    assert map_label("egg fried rice").canonical_label == "蛋炒饭"
    assert map_label("yangzhou fried rice").canonical_label == "扬州炒饭"
    assert map_label("bubble tea").canonical_label == "珍珠奶茶"
    assert map_label("ramen").fallback_label == "面条"
    assert map_label("totally unknown dish").canonical_label == "未知西餐"


def test_scores_pseudo_bbox_quality_from_product_rules() -> None:
    from scripts.training.build_food_rtdetr_v1_dataset import score_bbox_quality

    good = score_bbox_quality(
        image_width=1000,
        image_height=800,
        bbox_xyxy=[180, 120, 840, 700],
        bbox_type="pseudo_sam2",
        mask_area=320_000,
        predicted_iou=0.88,
        stability_score=0.91,
    )
    tiny = score_bbox_quality(
        image_width=1000,
        image_height=800,
        bbox_xyxy=[10, 10, 90, 80],
        bbox_type="pseudo_sam2",
        mask_area=3_000,
        predicted_iou=0.95,
        stability_score=0.95,
    )
    full = score_bbox_quality(
        image_width=1000,
        image_height=800,
        bbox_xyxy=[0, 0, 1000, 800],
        bbox_type="pseudo_sam2",
        mask_area=790_000,
        predicted_iou=0.95,
        stability_score=0.95,
    )

    assert good.keep is True
    assert good.score >= 0.75
    assert tiny.keep is False
    assert tiny.reasons == ["area_ratio_out_of_range"]
    assert full.keep is False
    assert "touches_full_image" in full.reasons


def test_builds_scaffold_and_converts_normalized_rows_to_coco(tmp_path: Path) -> None:
    from scripts.training.build_food_rtdetr_v1_dataset import build_food_rtdetr_v1

    source = tmp_path / "normalized_rows.jsonl"
    image_path = tmp_path / "images" / "sample.jpg"
    image_path.parent.mkdir()
    image_path.write_bytes(b"fake image bytes")
    rows = [
        {
            "image_path": str(image_path),
            "width": 1000,
            "height": 800,
            "source_dataset": "ChineseFoodNet",
            "original_label": "egg fried rice",
            "bbox": [180, 120, 840, 700],
            "bbox_format": "xyxy",
            "bbox_type": "pseudo_sam2",
            "split": "train",
            "quality_signals": {
                "mask_area": 320000,
                "predicted_iou": 0.88,
                "stability_score": 0.91,
            },
        },
        {
            "image_path": str(image_path),
            "width": 1000,
            "height": 800,
            "source_dataset": "UECFOOD-256",
            "original_label": "ramen",
            "bbox": [100, 100, 300, 280],
            "bbox_format": "xywh",
            "bbox_type": "real_bbox",
            "split": "val",
        },
    ]
    source.write_text("\n".join(json.dumps(row, ensure_ascii=False) for row in rows), encoding="utf-8")

    output_root = tmp_path / "food_rtdetr_v1"
    summary = build_food_rtdetr_v1(output_root=output_root, normalized_jsonl=source)

    assert summary == {
        "train": {"images": 1, "annotations": 1},
        "val": {"images": 1, "annotations": 1},
        "test": {"images": 0, "annotations": 0},
    }
    class_rows = list(csv.DictReader((output_root / "meta" / "class_map_v1.csv").open(encoding="utf-8")))
    assert {"canonical_label", "fallback_label", "tier", "group"} <= set(class_rows[0])
    assert any(row["canonical_label"] == "黄焖鸡米饭" for row in class_rows)

    source_rows = list(csv.DictReader((output_root / "meta" / "source_map.csv").open(encoding="utf-8")))
    chinese_food_net = next(row for row in source_rows if row["source_dataset"] == "ChineseFoodNet")
    assert chinese_food_net["license_risk"] == "research_only"

    train = json.loads((output_root / "annotations" / "train.json").read_text(encoding="utf-8"))
    assert train["images"][0]["source_dataset"] == "ChineseFoodNet"
    assert train["images"][0]["license_risk"] == "research_only"
    assert train["annotations"][0]["bbox_type"] == "pseudo_sam2"
    assert train["annotations"][0]["mapped_label"] == "蛋炒饭"
    assert train["annotations"][0]["quality_score"] >= 0.75

    val = json.loads((output_root / "annotations" / "val.json").read_text(encoding="utf-8"))
    assert val["annotations"][0]["bbox"] == [100.0, 100.0, 300.0, 280.0]
    assert val["annotations"][0]["mapped_label"] == "日式拉面"

    pseudo_scores = list(csv.DictReader((output_root / "meta" / "pseudo_label_score.csv").open(encoding="utf-8")))
    assert pseudo_scores[0]["source_dataset"] == "ChineseFoodNet"
    assert pseudo_scores[0]["mapped_label"] == "蛋炒饭"


def test_groups_multiple_annotations_for_the_same_image(tmp_path: Path) -> None:
    from scripts.training.build_food_rtdetr_v1_dataset import build_food_rtdetr_v1

    image_path = tmp_path / "images" / "shared.jpg"
    image_path.parent.mkdir()
    Image.new("RGB", (100, 80), "white").save(image_path)
    source = tmp_path / "rows.jsonl"
    rows = [
        {
            "image_path": str(image_path),
            "source_dataset": "FoodSeg103",
            "original_label": "rice",
            "bbox": [10, 12, 50, 52],
            "bbox_format": "xyxy",
            "bbox_type": "mask_to_bbox",
            "split": "train",
        },
        {
            "image_path": str(image_path),
            "source_dataset": "FoodSeg103",
            "original_label": "meat dish",
            "bbox": [56, 18, 92, 70],
            "bbox_format": "xyxy",
            "bbox_type": "mask_to_bbox",
            "split": "train",
        },
    ]
    source.write_text("\n".join(json.dumps(row, ensure_ascii=False) for row in rows), encoding="utf-8")

    output_root = tmp_path / "dataset"
    build_food_rtdetr_v1(output_root=output_root, normalized_jsonl=source)

    train = json.loads((output_root / "annotations" / "train.json").read_text(encoding="utf-8"))
    assert len(train["images"]) == 1
    assert len(train["annotations"]) == 2
    assert {annotation["image_id"] for annotation in train["annotations"]} == {train["images"][0]["id"]}


def test_copying_images_uses_unique_names_for_duplicate_basenames(tmp_path: Path) -> None:
    from scripts.training.build_food_rtdetr_v1_dataset import build_food_rtdetr_v1

    first = tmp_path / "source_a" / "same.jpg"
    second = tmp_path / "source_b" / "same.jpg"
    first.parent.mkdir()
    second.parent.mkdir()
    Image.new("RGB", (32, 32), "red").save(first)
    Image.new("RGB", (32, 32), "blue").save(second)
    source = tmp_path / "rows.jsonl"
    rows = [
        {
            "image_path": str(first),
            "source_dataset": "UECFOOD-256",
            "original_label": "rice",
            "bbox": [2, 2, 28, 28],
            "bbox_format": "xyxy",
            "bbox_type": "real_bbox",
            "split": "train",
        },
        {
            "image_path": str(second),
            "source_dataset": "UECFOOD-256",
            "original_label": "ramen",
            "bbox": [3, 3, 29, 29],
            "bbox_format": "xyxy",
            "bbox_type": "real_bbox",
            "split": "train",
        },
    ]
    source.write_text("\n".join(json.dumps(row, ensure_ascii=False) for row in rows), encoding="utf-8")

    output_root = tmp_path / "dataset"
    build_food_rtdetr_v1(output_root=output_root, normalized_jsonl=source)

    train = json.loads((output_root / "annotations" / "train.json").read_text(encoding="utf-8"))
    file_names = [image["file_name"] for image in train["images"]]
    assert len(file_names) == len(set(file_names)) == 2
    for file_name in file_names:
        assert (output_root / file_name).exists()


def test_stage4_checkpoint_fallback_does_not_run_ls_when_find_is_empty() -> None:
    script = Path("scripts/training/remote_food_rtdetr_stage4_clean_finetune.sh").read_text(encoding="utf-8")

    assert "xargs -r -0 ls -t" in script
    assert "xargs -0 ls -t" not in script


def test_filters_coco_to_specific_dish_labels_and_remaps_categories(tmp_path: Path) -> None:
    from scripts.training.filter_coco_specific_labels import filter_coco_specific_labels

    source_root = tmp_path / "source"
    (source_root / "annotations").mkdir(parents=True)
    (source_root / "images" / "train").mkdir(parents=True)
    Image.new("RGB", (32, 32), "white").save(source_root / "images" / "train" / "a.jpg")
    Image.new("RGB", (32, 32), "white").save(source_root / "images" / "train" / "b.jpg")
    payload = {
        "images": [
            {"id": 10, "file_name": "images/train/a.jpg", "width": 32, "height": 32},
            {"id": 11, "file_name": "images/train/b.jpg", "width": 32, "height": 32},
        ],
        "annotations": [
            {"id": 1, "image_id": 10, "category_id": 1, "bbox": [1, 2, 10, 12], "area": 120, "iscrowd": 0},
            {"id": 2, "image_id": 10, "category_id": 2, "bbox": [3, 4, 8, 8], "area": 64, "iscrowd": 0},
            {"id": 3, "image_id": 11, "category_id": 3, "bbox": [5, 6, 9, 9], "area": 81, "iscrowd": 0},
        ],
        "categories": [
            {"id": 1, "name": "炒饭"},
            {"id": 2, "name": "未知西餐"},
            {"id": 3, "name": "汉堡"},
        ],
    }
    for split in ("train", "val", "test"):
        (source_root / "annotations" / f"{split}.json").write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")

    output_root = tmp_path / "specific"
    summary = filter_coco_specific_labels(source_root=source_root, output_root=output_root)

    assert summary["suggested_num_classes"] == 3
    assert summary["train"]["categories"] == 2
    assert summary["train"]["annotations"] == 2
    train = json.loads((output_root / "annotations" / "train.json").read_text(encoding="utf-8"))
    assert train["categories"] == [{"id": 1, "name": "炒饭"}, {"id": 2, "name": "汉堡"}]
    assert {annotation["category_id"] for annotation in train["annotations"]} == {1, 2}
    assert {Path(image["file_name"]).name for image in train["images"]} == {"a.jpg", "b.jpg"}


def test_specific_filter_can_drop_low_count_specific_classes(tmp_path: Path) -> None:
    from scripts.training.filter_coco_specific_labels import filter_coco_specific_labels

    source_root = tmp_path / "source"
    (source_root / "annotations").mkdir(parents=True)
    payload = {
        "images": [{"id": 1, "file_name": "/abs/a.jpg", "width": 10, "height": 10}],
        "annotations": [{"id": 1, "image_id": 1, "category_id": 1, "bbox": [0, 0, 5, 5], "area": 25, "iscrowd": 0}],
        "categories": [{"id": 1, "name": "炒饭"}],
    }
    for split in ("train", "val", "test"):
        (source_root / "annotations" / f"{split}.json").write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")

    output_root = tmp_path / "specific"
    summary = filter_coco_specific_labels(source_root=source_root, output_root=output_root, min_train_annotations=2)

    assert summary["suggested_num_classes"] == 1
    train = json.loads((output_root / "annotations" / "train.json").read_text(encoding="utf-8"))
    assert train["categories"] == []
    assert train["annotations"] == []


def test_checkpoint_janitor_script_cleans_stage3_and_stage4_checkpoints_safely() -> None:
    script = Path("scripts/training/remote_food_rtdetr_checkpoint_janitor.sh").read_text(encoding="utf-8")

    assert "stage3_r101_800px_40e" in script
    assert "r101_800px_clean_finetune" in script
    assert 'CHECKPOINT_GLOB="${CHECKPOINT_GLOB:-checkpoint*.pth}"' in script
    assert 'KEEP_RECENT="${KEEP_RECENT:-3}"' in script
    assert 'MIN_AGE_MINUTES="${MIN_AGE_MINUTES:-20}"' in script
    assert 'rm -f -- "${checkpoint}"' in script
    assert "df -h /root/autodl-tmp" in script
    assert "while true; do" in script


def test_converts_uecfoodpix_semantic_masks_to_normalized_rows(tmp_path: Path) -> None:
    from scripts.training.build_food_rtdetr_v1_dataset import convert_uecfoodpix_to_normalized_jsonl

    dataset_root = tmp_path / "UECFoodPixComplete"
    (dataset_root / "train" / "img").mkdir(parents=True)
    (dataset_root / "train" / "mask").mkdir(parents=True)
    (dataset_root / "test" / "img").mkdir(parents=True)
    (dataset_root / "test" / "mask").mkdir(parents=True)
    (dataset_root / "category.txt").write_text("0 background\n1 rice\n2 meat dish\n", encoding="utf-8")
    Image.new("RGB", (8, 6), "white").save(dataset_root / "train" / "img" / "0001.jpg")
    mask = Image.new("L", (8, 6), 0)
    pixels = mask.load()
    for x in range(1, 5):
        for y in range(2, 5):
            pixels[x, y] = 1
    for x in range(5, 8):
        for y in range(1, 3):
            pixels[x, y] = 2
    mask.save(dataset_root / "train" / "mask" / "0001.png")
    Image.new("RGB", (8, 6), "white").save(dataset_root / "test" / "img" / "0002.jpg")
    Image.new("L", (8, 6), 1).save(dataset_root / "test" / "mask" / "0002.png")

    output_jsonl = tmp_path / "uecfoodpix.jsonl"
    count = convert_uecfoodpix_to_normalized_jsonl(dataset_root, output_jsonl)

    rows = [json.loads(line) for line in output_jsonl.read_text(encoding="utf-8").splitlines()]
    assert count == 3
    assert rows[0]["source_dataset"] == "UECFoodPixComplete"
    assert rows[0]["bbox_type"] == "mask_to_bbox"
    assert rows[0]["bbox"] == [1, 2, 5, 5]
    assert rows[0]["quality_signals"]["mask_area"] == 12
    assert {row["split"] for row in rows} == {"train", "val"}


def test_converts_nested_uecfoodpix_archive_layout(tmp_path: Path) -> None:
    from scripts.training.build_food_rtdetr_v1_dataset import convert_uecfoodpix_to_normalized_jsonl

    dataset_root = tmp_path / "data"
    nested = dataset_root / "UECFoodPIXCOMPLETE"
    (nested / "train" / "img").mkdir(parents=True)
    (nested / "train" / "mask").mkdir(parents=True)
    (dataset_root / "category.txt").write_text("id\tname\n1\trice\n", encoding="utf-8")
    Image.new("RGB", (5, 5), "white").save(nested / "train" / "img" / "1.jpg")
    mask = Image.new("L", (5, 5), 0)
    pixels = mask.load()
    for x in range(2, 5):
        for y in range(1, 4):
            pixels[x, y] = 1
    mask.save(nested / "train" / "mask" / "1.png")

    output_jsonl = tmp_path / "nested.jsonl"
    count = convert_uecfoodpix_to_normalized_jsonl(dataset_root, output_jsonl)

    rows = [json.loads(line) for line in output_jsonl.read_text(encoding="utf-8").splitlines()]
    assert count == 1
    assert rows[0]["bbox"] == [2, 1, 5, 4]


def test_converts_foodseg_semantic_masks_to_normalized_rows(tmp_path: Path) -> None:
    from scripts.training.build_food_rtdetr_v1_dataset import convert_foodseg_to_normalized_jsonl

    dataset_root = tmp_path / "FoodSeg103"
    (dataset_root / "Images" / "img_dir" / "train").mkdir(parents=True)
    (dataset_root / "Images" / "ann_dir" / "train").mkdir(parents=True)
    (dataset_root / "Images" / "img_dir" / "test").mkdir(parents=True)
    (dataset_root / "Images" / "ann_dir" / "test").mkdir(parents=True)
    Image.new("RGB", (7, 6), "white").save(dataset_root / "Images" / "img_dir" / "train" / "a.jpg")
    mask = Image.new("L", (7, 6), 0)
    pixels = mask.load()
    for x in range(1, 4):
        for y in range(1, 5):
            pixels[x, y] = 66
    for x in range(4, 7):
        for y in range(2, 4):
            pixels[x, y] = 47
    mask.save(dataset_root / "Images" / "ann_dir" / "train" / "a.png")
    Image.new("RGB", (5, 5), "white").save(dataset_root / "Images" / "img_dir" / "test" / "b.jpg")
    Image.new("L", (5, 5), 102).save(dataset_root / "Images" / "ann_dir" / "test" / "b.png")

    output_jsonl = tmp_path / "foodseg.jsonl"
    count = convert_foodseg_to_normalized_jsonl(dataset_root, output_jsonl)

    rows = [json.loads(line) for line in output_jsonl.read_text(encoding="utf-8").splitlines()]
    assert count == 3
    assert rows[0]["source_dataset"] == "FoodSeg103"
    assert rows[0]["original_label"] == "pork"
    assert rows[0]["bbox_type"] == "mask_to_bbox"
    assert rows[0]["bbox"] == [4, 2, 7, 4]
    assert rows[1]["original_label"] == "rice"
    assert rows[1]["bbox"] == [1, 1, 4, 5]
    assert rows[2]["original_label"] == "salad"
    assert {row["split"] for row in rows} == {"train", "val"}


def test_converts_huggingface_foodseg_records_to_mask_bbox_rows(tmp_path: Path) -> None:
    from scripts.training.build_food_rtdetr_v1_dataset import convert_foodseg_hf_records_to_normalized_jsonl

    train_image = Image.new("RGB", (7, 6), "white")
    train_mask = Image.new("L", (7, 6), 0)
    train_pixels = train_mask.load()
    for x in range(1, 4):
        for y in range(1, 5):
            train_pixels[x, y] = 66
    for x in range(4, 7):
        for y in range(2, 4):
            train_pixels[x, y] = 48
    val_image = Image.new("RGB", (5, 5), "white")
    val_mask = Image.new("L", (5, 5), 102)

    output_jsonl = tmp_path / "foodseg_hf.jsonl"
    image_output_root = tmp_path / "foodseg_hf_images"
    count = convert_foodseg_hf_records_to_normalized_jsonl(
        {
            "train": [{"id": "train/a", "image": train_image, "label": train_mask}],
            "validation": [{"id": "val/b", "image": val_image, "label": val_mask}],
        },
        output_jsonl=output_jsonl,
        image_output_root=image_output_root,
    )

    rows = [json.loads(line) for line in output_jsonl.read_text(encoding="utf-8").splitlines()]
    assert count == 3
    assert all(Path(row["image_path"]).exists() for row in rows)
    assert {row["split"] for row in rows} == {"train", "val"}
    by_label = {row["original_label"]: row for row in rows}
    assert by_label["chicken duck"]["bbox"] == [4, 2, 7, 4]
    assert by_label["rice"]["bbox"] == [1, 1, 4, 5]
    assert by_label["salad"]["bbox"] == [0, 0, 5, 5]
    assert by_label["rice"]["bbox_type"] == "mask_to_bbox"
    assert by_label["rice"]["source_dataset"] == "FoodSeg103"


def test_converts_single_label_image_folders_to_pseudo_rows(tmp_path: Path) -> None:
    from scripts.training.build_food_rtdetr_v1_dataset import convert_classification_folder_to_normalized_jsonl

    dataset_root = tmp_path / "Food-101"
    (dataset_root / "train" / "egg_fried_rice").mkdir(parents=True)
    (dataset_root / "validation" / "bubble_tea").mkdir(parents=True)
    Image.new("RGB", (100, 60), "white").save(dataset_root / "train" / "egg_fried_rice" / "a.jpg")
    Image.new("RGB", (80, 40), "white").save(dataset_root / "validation" / "bubble_tea" / "b.jpg")

    output_jsonl = tmp_path / "food101_pseudo.jsonl"
    count = convert_classification_folder_to_normalized_jsonl(
        dataset_root=dataset_root,
        output_jsonl=output_jsonl,
        source_dataset="Food-101",
        bbox_margin_ratio=0.08,
        default_confidence=0.58,
    )

    rows = [json.loads(line) for line in output_jsonl.read_text(encoding="utf-8").splitlines()]
    assert count == 2
    assert rows[0]["source_dataset"] == "Food-101"
    assert rows[0]["original_label"] == "egg fried rice"
    assert rows[0]["bbox"] == [8, 5, 92, 55]
    assert rows[0]["bbox_type"] == "pseudo_single_label"
    assert rows[0]["split"] == "train"
    assert rows[0]["quality_signals"] == {
        "mask_area": 4200,
        "predicted_iou": 0.58,
        "stability_score": 0.58,
    }
    assert rows[1]["original_label"] == "bubble tea"
    assert rows[1]["bbox"] == [6, 3, 74, 37]
    assert rows[1]["split"] == "val"


def test_classification_folder_uses_food101_meta_splits(tmp_path: Path) -> None:
    from scripts.training.build_food_rtdetr_v1_dataset import convert_classification_folder_to_normalized_jsonl

    dataset_root = tmp_path / "food-101"
    (dataset_root / "images" / "ramen").mkdir(parents=True)
    (dataset_root / "meta").mkdir(parents=True)
    Image.new("RGB", (50, 50), "white").save(dataset_root / "images" / "ramen" / "train_item.jpg")
    Image.new("RGB", (50, 50), "white").save(dataset_root / "images" / "ramen" / "test_item.jpg")
    (dataset_root / "meta" / "train.txt").write_text("ramen/train_item\n", encoding="utf-8")
    (dataset_root / "meta" / "test.txt").write_text("ramen/test_item\n", encoding="utf-8")

    output_jsonl = tmp_path / "food101_meta.jsonl"
    convert_classification_folder_to_normalized_jsonl(
        dataset_root=dataset_root,
        output_jsonl=output_jsonl,
        source_dataset="Food-101",
    )

    rows = [json.loads(line) for line in output_jsonl.read_text(encoding="utf-8").splitlines()]
    split_by_image = {Path(row["image_path"]).stem: row["split"] for row in rows}
    assert split_by_image == {"train_item": "train", "test_item": "val"}


def test_converts_csv_classification_rows_to_pseudo_rows(tmp_path: Path) -> None:
    from scripts.training.build_food_rtdetr_v1_dataset import convert_csv_classification_to_normalized_jsonl

    image_root = tmp_path / "FoodX-251" / "train"
    image_root.mkdir(parents=True)
    Image.new("RGB", (120, 80), "white").save(image_root / "train_000001.jpg")
    class_list = tmp_path / "class_list.txt"
    class_list.write_text("0 macaron\n1 beignet\n", encoding="utf-8")
    labels_csv = tmp_path / "train_info.csv"
    labels_csv.write_text("train_000001.jpg,1\nmissing.jpg,0\n", encoding="utf-8")

    output_jsonl = tmp_path / "foodx_train.jsonl"
    count = convert_csv_classification_to_normalized_jsonl(
        image_root=image_root,
        labels_csv=labels_csv,
        class_list=class_list,
        output_jsonl=output_jsonl,
        source_dataset="FoodX-251",
        split="train",
        bbox_margin_ratio=0.1,
        default_confidence=0.52,
    )

    rows = [json.loads(line) for line in output_jsonl.read_text(encoding="utf-8").splitlines()]
    assert count == 1
    assert rows[0]["source_dataset"] == "FoodX-251"
    assert rows[0]["original_label"] == "beignet"
    assert rows[0]["bbox"] == [12, 8, 108, 72]
    assert rows[0]["bbox_type"] == "pseudo_single_label"
    assert rows[0]["split"] == "train"
    assert rows[0]["quality_signals"]["predicted_iou"] == 0.52


def test_csv_classification_converter_finds_images_in_nested_split_dir(tmp_path: Path) -> None:
    from scripts.training.build_food_rtdetr_v1_dataset import convert_csv_classification_to_normalized_jsonl

    image_root = tmp_path / "FoodX-251" / "train"
    (image_root / "train_set").mkdir(parents=True)
    Image.new("RGB", (40, 40), "white").save(image_root / "train_set" / "train_000001.jpg")
    class_list = tmp_path / "class_list.txt"
    class_list.write_text("0 macaron\n", encoding="utf-8")
    labels_csv = tmp_path / "train_info.csv"
    labels_csv.write_text("train_000001.jpg,0\n", encoding="utf-8")

    output_jsonl = tmp_path / "nested_foodx.jsonl"
    count = convert_csv_classification_to_normalized_jsonl(
        image_root=image_root,
        labels_csv=labels_csv,
        class_list=class_list,
        output_jsonl=output_jsonl,
        source_dataset="FoodX-251",
        split="train",
    )

    rows = [json.loads(line) for line in output_jsonl.read_text(encoding="utf-8").splitlines()]
    assert count == 1
    assert Path(rows[0]["image_path"]).parent.name == "train_set"


def test_foodx_policy_is_research_only() -> None:
    from scripts.training.build_food_rtdetr_v1_dataset import get_source_policy

    assert get_source_policy("FoodX-251").license_risk == "research_only"


def test_commercial_candidate_excludes_research_only_pseudo_rows(tmp_path: Path) -> None:
    from scripts.training.build_food_rtdetr_v1_dataset import build_food_rtdetr_v1

    image_path = tmp_path / "food101.jpg"
    Image.new("RGB", (100, 60), "white").save(image_path)
    rows = [
        {
            "image_path": str(image_path),
            "width": 100,
            "height": 60,
            "source_dataset": "Food-101",
            "original_label": "egg fried rice",
            "bbox": [8, 5, 92, 55],
            "bbox_format": "xyxy",
            "bbox_type": "pseudo_single_label",
            "split": "train",
            "quality_signals": {"mask_area": 4200, "predicted_iou": 0.58, "stability_score": 0.58},
        }
    ]
    source = tmp_path / "rows.jsonl"
    source.write_text("\n".join(json.dumps(row, ensure_ascii=False) for row in rows), encoding="utf-8")

    summary = build_food_rtdetr_v1(
        output_root=tmp_path / "dataset",
        normalized_jsonl=source,
        license_policy="commercial_candidate",
    )

    assert summary["train"] == {"images": 0, "annotations": 0}


def test_build_can_reference_source_images_without_copying(tmp_path: Path) -> None:
    from scripts.training.build_food_rtdetr_v1_dataset import build_food_rtdetr_v1

    image_path = tmp_path / "source" / "ramen.jpg"
    image_path.parent.mkdir()
    Image.new("RGB", (80, 80), "white").save(image_path)
    source = tmp_path / "rows.jsonl"
    row = {
        "image_path": str(image_path),
        "width": 80,
        "height": 80,
        "source_dataset": "UECFOOD-256",
        "original_label": "ramen",
        "bbox": [8, 8, 72, 72],
        "bbox_format": "xyxy",
        "bbox_type": "real_bbox",
        "split": "train",
    }
    source.write_text(json.dumps(row, ensure_ascii=False) + "\n", encoding="utf-8")

    output_root = tmp_path / "dataset"
    build_food_rtdetr_v1(output_root=output_root, normalized_jsonl=source, copy_images=False)

    train = json.loads((output_root / "annotations" / "train.json").read_text(encoding="utf-8"))
    assert train["images"][0]["file_name"] == str(image_path)
    assert not any((output_root / "images" / "train").glob("*.jpg"))


def test_public_specific_builder_keeps_chinese_foodnet_dish_names(tmp_path: Path) -> None:
    from scripts.training.build_public_food_coco import build_public_food_coco

    image_path = tmp_path / "ChineseFoodNet" / "train" / "000" / "mapo.jpg"
    image_path.parent.mkdir(parents=True)
    Image.new("RGB", (100, 80), "white").save(image_path)
    source = tmp_path / "rows.jsonl"
    rows = [
        {
            "image_path": str(image_path),
            "width": 100,
            "height": 80,
            "source_dataset": "ChineseFoodNet",
            "original_label": "麻婆豆腐",
            "bbox": [8, 6, 92, 74],
            "bbox_format": "xyxy",
            "bbox_type": "pseudo_single_label",
            "split": "train",
            "quality_signals": {"mask_area": 5712, "predicted_iou": 0.58, "stability_score": 0.58},
        }
    ]
    source.write_text("\n".join(json.dumps(row, ensure_ascii=False) for row in rows), encoding="utf-8")

    output_root = tmp_path / "public_specific"
    summary = build_public_food_coco(
        output_root=output_root,
        normalized_jsonl_paths=[source],
        min_train_annotations=1,
    )

    assert summary["suggested_num_classes"] == 2
    train = json.loads((output_root / "annotations" / "train.json").read_text(encoding="utf-8"))
    assert train["categories"] == [{"id": 1, "name": "麻婆豆腐"}]
    assert train["annotations"][0]["mapped_label"] == "麻婆豆腐"


def test_public_specific_builder_collapses_foodseg_to_food_region(tmp_path: Path) -> None:
    from scripts.training.build_public_food_coco import build_public_food_coco

    image_path = tmp_path / "FoodSeg103" / "image.jpg"
    image_path.parent.mkdir(parents=True)
    Image.new("RGB", (100, 80), "white").save(image_path)
    source = tmp_path / "foodseg_rows.jsonl"
    rows = [
        {
            "image_path": str(image_path),
            "width": 100,
            "height": 80,
            "source_dataset": "FoodSeg103",
            "original_label": "pork",
            "bbox": [10, 12, 40, 50],
            "bbox_format": "xyxy",
            "bbox_type": "mask_to_bbox",
            "split": "train",
            "quality_signals": {"mask_area": 1140},
        },
        {
            "image_path": str(image_path),
            "width": 100,
            "height": 80,
            "source_dataset": "FoodSeg103",
            "original_label": "rice",
            "bbox": [35, 20, 90, 70],
            "bbox_format": "xyxy",
            "bbox_type": "mask_to_bbox",
            "split": "train",
            "quality_signals": {"mask_area": 2750},
        },
    ]
    source.write_text("\n".join(json.dumps(row, ensure_ascii=False) for row in rows), encoding="utf-8")

    output_root = tmp_path / "public_region"
    build_public_food_coco(
        output_root=output_root,
        normalized_jsonl_paths=[source],
        foodseg_mode="union",
        min_train_annotations=1,
    )

    train = json.loads((output_root / "annotations" / "train.json").read_text(encoding="utf-8"))
    assert train["categories"] == [{"id": 1, "name": "食物区域"}]
    assert len(train["annotations"]) == 1
    assert train["annotations"][0]["bbox"] == [10.0, 12.0, 80.0, 58.0]


def test_public_specific_builder_can_skip_foodseg_for_final_dish_training(tmp_path: Path) -> None:
    from scripts.training.build_public_food_coco import build_public_food_coco

    image_path = tmp_path / "FoodSeg103" / "image.jpg"
    image_path.parent.mkdir(parents=True)
    Image.new("RGB", (20, 20), "white").save(image_path)
    source = tmp_path / "foodseg_rows.jsonl"
    source.write_text(
        json.dumps(
            {
                "image_path": str(image_path),
                "width": 20,
                "height": 20,
                "source_dataset": "FoodSeg103",
                "original_label": "pork",
                "bbox": [1, 1, 10, 10],
                "bbox_format": "xyxy",
                "bbox_type": "mask_to_bbox",
                "split": "train",
            },
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )

    summary = build_public_food_coco(
        output_root=tmp_path / "public_no_foodseg",
        normalized_jsonl_paths=[source],
        foodseg_mode="skip",
        min_train_annotations=1,
    )

    assert summary["train"] == {"images": 0, "annotations": 0, "categories": 0}


def test_public_specific_builder_drops_images_above_pixel_limit(tmp_path: Path) -> None:
    from scripts.training.build_public_food_coco import build_public_food_coco

    image_path = tmp_path / "huge_metadata.jpg"
    Image.new("RGB", (20, 20), "white").save(image_path)
    source = tmp_path / "rows.jsonl"
    source.write_text(
        json.dumps(
            {
                "image_path": str(image_path),
                "width": 20000,
                "height": 10000,
                "source_dataset": "ChineseFoodNet",
                "original_label": "麻婆豆腐",
                "bbox": [100, 100, 1000, 1000],
                "bbox_format": "xyxy",
                "bbox_type": "pseudo_single_label",
                "split": "train",
            },
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )

    summary = build_public_food_coco(
        output_root=tmp_path / "public_filtered",
        normalized_jsonl_paths=[source],
        min_train_annotations=1,
        max_image_pixels=178_956_970,
    )

    assert summary["train"] == {"images": 0, "annotations": 0, "categories": 0}
    assert summary["dropped"]["image_too_large"] == 1


def test_converts_existing_coco_dataset_to_normalized_rows(tmp_path: Path) -> None:
    from scripts.training.build_food_rtdetr_v1_dataset import convert_coco_dataset_to_normalized_jsonl

    dataset_root = tmp_path / "research_full"
    image_path = dataset_root / "images" / "train" / "ramen.jpg"
    image_path.parent.mkdir(parents=True)
    Image.new("RGB", (80, 60), "white").save(image_path)
    (dataset_root / "annotations").mkdir()
    coco = {
        "images": [
            {
                "id": 7,
                "file_name": "images/train/ramen.jpg",
                "width": 80,
                "height": 60,
                "source_dataset": "UECFOOD-256",
                "original_label": "ramen",
            }
        ],
        "annotations": [
            {
                "id": 3,
                "image_id": 7,
                "bbox": [8, 6, 64, 48],
                "source_dataset": "UECFOOD-256",
                "original_label": "ramen",
                "bbox_type": "real_bbox",
            }
        ],
        "categories": [],
    }
    (dataset_root / "annotations" / "train.json").write_text(json.dumps(coco), encoding="utf-8")

    output_jsonl = tmp_path / "from_coco.jsonl"
    count = convert_coco_dataset_to_normalized_jsonl(dataset_root, output_jsonl, splits=("train",))

    rows = [json.loads(line) for line in output_jsonl.read_text(encoding="utf-8").splitlines()]
    assert count == 1
    assert rows[0]["image_path"] == str(image_path)
    assert rows[0]["bbox"] == [8, 6, 64, 48]
    assert rows[0]["bbox_format"] == "xywh"
    assert rows[0]["split"] == "train"


def test_remote_training_script_exposes_product_r101_controls() -> None:
    script = Path("scripts/training/remote_food_rtdetr_v1_train.sh").read_text(encoding="utf-8")

    assert 'INPUT_SIZE="${INPUT_SIZE:-800}"' in script
    assert 'DATASET_ROOT="${DATASET_ROOT:-${WORK_ROOT}/research_full}"' in script
    assert "PRETRAINED_CKPT=\"${PRETRAINED_CKPT:-${CHECKPOINT_ROOT}/${MODEL_CONFIG_NAME}.pth}\"" in script
    assert "eval_spatial_size: [${INPUT_SIZE}, ${INPUT_SIZE}]" in script
    assert "{type: RandomPhotometricDistort, p: 0.5}" in script
    assert "{type: RandomIoUCrop, p: 0.8}" in script
    assert "{type: Resize, size: [${INPUT_SIZE}, ${INPUT_SIZE}]}" in script
    assert "BatchImageCollateFunction" in script
    assert "${INPUT_SIZE}, 832, 864, 896, 928, 960, 1024" in script
    assert 'START_TRAIN="${START_TRAIN:-1}"' in script
    assert 'COPY_IMAGES="${COPY_IMAGES:-1}"' in script
    assert 'copy_args+=(--no-copy-images)' in script
    assert 'CHECKPOINT_FREQ="${CHECKPOINT_FREQ:-5}"' in script
    assert 'SMOKE_CHECKPOINT_FREQ="${SMOKE_CHECKPOINT_FREQ:-1}"' in script
    assert 'TRAIN_FAILURE_PATTERN="${TRAIN_FAILURE_PATTERN:-Traceback|CUDA out of memory|RuntimeError|Exception|Killed}"' in script
    assert "grep -Eq '${TRAIN_FAILURE_PATTERN}'" in script
    assert 'write_train_config "${CONFIG_ROOT}/food_rtdetrv1_smoke.yml" "${SMOKE_EPOCHES}" "${SMOKE_CHECKPOINT_FREQ}"' in script
    assert 'write_train_config "${CONFIG_ROOT}/food_rtdetrv1_full.yml" "${EPOCHES}" "${CHECKPOINT_FREQ}"' in script
    assert 'if [[ "${START_TRAIN}" != "1" ]]; then' in script
    assert "wait_for_existing_download \"${out}\"" in script
    assert "collect_uecfoodpix" in script
    assert "UECFOODPIXCOMPLETE.tar" in script
    assert "convert-uecfoodpix" in script
    assert "collect_foodseg103" in script
    assert "FoodSeg103.zip" in script
    assert "convert-foodseg" in script
    assert "collect_existing_classification_dirs" in script
    assert "CLASSIFICATION_DATASET_ROOTS" in script
    assert "convert-class-dir" in script
    assert 'COLLECT_FOOD101_OFFICIAL="${COLLECT_FOOD101_OFFICIAL:-0}"' in script
    assert "FOOD101_OFFICIAL_URL" in script
    assert "collect_food101_official" in script
    assert "food-101.tar.gz" in script
    assert 'COLLECT_FOODX251="${COLLECT_FOODX251:-0}"' in script
    assert "FOODX251_TRAIN_URL" in script
    assert "collect_foodx251" in script
    assert "convert-class-csv" in script
    assert 'if [[ "${FOOD_RTDETR_SOURCE_ONLY:-0}" != "1" ]]; then' in script


def test_product_launcher_queues_r101_after_preparation_and_smoke() -> None:
    script = Path("scripts/training/remote_food_rtdetr_product_launcher.sh").read_text(encoding="utf-8")

    assert 'PREPARE_SESSION="${PREPARE_SESSION:-food_rtdetr_prepare}"' in script
    assert 'SMOKE_SESSION="${SMOKE_SESSION:-food_rtdetr_r101_uec100_smoke}"' in script
    assert 'CHECKPOINT_SESSION="${CHECKPOINT_SESSION:-food_rtdetr_r101_ckpt}"' in script
    assert "hf-mirror.com/yours-mykola/rt-detr-v2-r101vd" in script
    assert 'MIN_CHECKPOINT_BYTES="${MIN_CHECKPOINT_BYTES:-300000000}"' in script
    assert "MODEL_CONFIG_NAME=rtdetrv2_r101vd_6x_coco" in script
    assert 'EPOCHES="${EPOCHES:-220}"' in script
    assert 'INPUT_SIZE="${INPUT_SIZE:-800}"' in script
    assert 'EPOCHES="${EPOCHES}"' in script
    assert 'INPUT_SIZE="${INPUT_SIZE}"' in script
    assert "AUTO_START_FULL_AFTER_SMOKE=1" in script


def test_stage3_dataset_script_merges_research_sources_without_copying() -> None:
    script = Path("scripts/training/remote_food_rtdetr_stage3_dataset.sh").read_text(encoding="utf-8")

    assert "BASE_COCO_DATASET_ROOT" in script
    assert "/root/autodl-tmp/food_rtdetr_v2_mask/research_full" in script
    assert "convert-coco" in script
    assert "base_coco_existing.jsonl" in script
    assert '! -name "$(basename "${BASE_NORMALIZED_JSONL}")"' in script
    assert "BASE_NORMALIZED_JSONL" in script
    assert "stage3_research_all.jsonl" in script
    assert 'COPY_IMAGES="${COPY_IMAGES:-0}"' in script
    assert "copy_args+=(--no-copy-images)" in script
    assert 'license-policy "${LICENSE_POLICY}"' in script
    assert "source_counts.csv" in script


def test_remote_monitor_script_records_stage3_training_health() -> None:
    script = Path("scripts/training/remote_food_rtdetr_monitor.sh").read_text(encoding="utf-8")

    assert 'WORK_ROOT="${WORK_ROOT:-/root/autodl-tmp/food_rtdetr_stage3}"' in script
    assert 'SCREEN_NAME="${SCREEN_NAME:-stage3_full_train}"' in script
    assert 'TRAIN_LOG="${TRAIN_LOG:-${WORK_ROOT}/logs/stage3_full_train.log}"' in script
    assert 'STATUS_JSONL="${STATUS_JSONL:-${WORK_ROOT}/logs/stage3_full_monitor.jsonl}"' in script
    assert "CUDA out of memory" in script
    assert "device-side assert" in script
    assert 'REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"' in script
    assert 'PYTHONPATH="${REPO_ROOT}${PYTHONPATH:+:${PYTHONPATH}}"' in script
    assert "-m scripts.training.food_rtdetr_stage3_monitor" in script
    assert 'MODE="${1:-once}"' in script
    assert 'while true; do' in script


def test_stage3_monitor_parser_ignores_epoch_summary_lines() -> None:
    from scripts.training.food_rtdetr_stage3_monitor import parse_train_log_text

    text = "\n".join(
        [
            "Epoch: [0]  [30592/30593]  eta: 0:00:00  lr: 0.000001  loss: 10.5270 (15.4373)",
            "Epoch: [0] Total time: 5:22:55 (0.6333 s / it)",
            "Test:  [5638/5639]  eta: 0:00:00    time: 0.3202  data: 0.0246",
            "Average Precision  (AP) @[ IoU=0.50:0.95 | area=   all | maxDets=100 ] = 0.220",
            "Epoch: [1]  [   80/30593]  eta: 5:31:12  lr: 0.000001  loss: 12.8749 (12.2151)",
        ]
    )

    parsed = parse_train_log_text(text, failure_pattern="RuntimeError|Traceback")

    assert parsed["latest_progress"].startswith("Epoch: [1]  [   80/30593]")
    assert parsed["epoch"] == 1
    assert parsed["iteration"] == 80
    assert parsed["total_iterations"] == 30593
    assert parsed["latest_test_progress"].startswith("Test:  [5638/5639]")
    assert parsed["test_iteration"] == 5638
    assert parsed["test_total_iterations"] == 5639
    assert parsed["failure_matches"] == []


def test_stage4_clean_finetune_script_uses_stage3_checkpoint_and_clean_bbox_data() -> None:
    script = Path("scripts/training/remote_food_rtdetr_stage4_clean_finetune.sh").read_text(encoding="utf-8")

    assert 'CLEAN_DATASET_ROOT="${CLEAN_DATASET_ROOT:-/root/autodl-tmp/food_rtdetr_v2_mask/research_full}"' in script
    assert 'STAGE3_OUTPUT_DIR="${STAGE3_OUTPUT_DIR:-/root/autodl-tmp/food_rtdetr_stage3/output/stage3_r101_800px_40e}"' in script
    assert 'OUTPUT_DIR="${OUTPUT_DIR:-/root/autodl-tmp/food_rtdetr_stage4_clean/output/r101_800px_clean_finetune}"' in script
    assert "find_stage3_checkpoint" in script
    assert "best.pth" in script
    assert "last.pth" in script
    assert "checkpoint*.pth" in script
    assert 'WAIT_FOR_CKPT="${WAIT_FOR_CKPT:-0}"' in script
    assert 'START_TRAIN="${START_TRAIN:-1}"' in script
    assert 'NUM_CLASSES="${NUM_CLASSES:-163}"' in script
    assert "num_classes: ${NUM_CLASSES}" in script
    assert 'COLLATE_SCALES="${COLLATE_SCALES:-640, 672, 704, 736, 768, ${INPUT_SIZE}, 832, 864, 896, 928, 960, 1024}"' in script
    assert "scales: [${COLLATE_SCALES}]" in script
    assert "remap_mscoco_category: False" in script
    assert "ann_file: ${CLEAN_DATASET_ROOT}/annotations/train.json" in script
    assert "ann_file: ${CLEAN_DATASET_ROOT}/annotations/val.json" in script
    assert "tools/train.py" in script
    assert "-c ${CONFIG_PATH}" in script
    assert "--use-amp" in script
    assert "screen -dmS" in script


def test_foodseg_hf_parquet_collect_script_downloads_and_converts_direct_mirror_files() -> None:
    script = Path("scripts/training/remote_foodseg_hf_parquet_collect.sh").read_text(encoding="utf-8")

    assert "hf-mirror.com/datasets/EduardoPacheco/FoodSeg103/resolve/main/data" in script
    assert "train-00000-of-00003.parquet" in script
    assert "train-00001-of-00003.parquet" in script
    assert "train-00002-of-00003.parquet" in script
    assert "validation-00000-of-00001.parquet" in script
    assert "convert-foodseg-hf-parquet" in script
    assert "FoodSeg103_hf_mask_to_bbox.jsonl" in script
    assert 'IMAGE_ROOT="${IMAGE_ROOT:-${WORK_ROOT}/raw_datasets/FoodSeg103HF/images}"' in script
    assert 'PARQUET_ROOT="${PARQUET_ROOT:-${WORK_ROOT}/raw_datasets/FoodSeg103HF/parquet}"' in script
    assert "wget -c" in script
    assert "wc -l" in script


def test_stage4_watch_script_waits_for_completed_stage3_before_launching_clean_finetune() -> None:
    script = Path("scripts/training/remote_food_rtdetr_stage4_after_stage3_watch.sh").read_text(encoding="utf-8")

    assert 'STAGE3_SCREEN="${STAGE3_SCREEN:-stage3_full_train}"' in script
    assert 'STAGE3_LOG="${STAGE3_LOG:-${STAGE3_WORK_ROOT}/logs/stage3_full_train.log}"' in script
    assert 'STAGE3_OUTPUT_DIR="${STAGE3_OUTPUT_DIR:-${STAGE3_WORK_ROOT}/output/stage3_r101_800px_40e}"' in script
    assert 'STAGE4_SCRIPT="${STAGE4_SCRIPT:-/root/autodl-tmp/cal-repro/scripts/training/remote_food_rtdetr_stage4_clean_finetune.sh}"' in script
    assert "Training time" in script
    assert "CUDA out of memory" in script
    assert "device-side assert" in script
    assert "best.pth" in script
    assert "last.pth" in script
    assert "checkpoint*.pth" in script
    assert "xargs -r -0 ls -t" in script
    assert "stage4_clean_finetune" in script
    assert 'START_STAGE4="${START_STAGE4:-1}"' in script
    assert 'while true; do' in script
    assert 'MODE="${1:-loop}"' in script
    assert 'STAGE3_CKPT="${ckpt}"' in script


def test_stage5_eval_export_script_builds_clean_test_config_and_onnx_manifest() -> None:
    script = Path("scripts/training/remote_food_rtdetr_stage5_eval_export.sh").read_text(encoding="utf-8")

    assert 'STAGE4_OUTPUT_DIR="${STAGE4_OUTPUT_DIR:-/root/autodl-tmp/food_rtdetr_stage4_clean/output/r101_800px_clean_finetune}"' in script
    assert 'CLEAN_DATASET_ROOT="${CLEAN_DATASET_ROOT:-/root/autodl-tmp/food_rtdetr_v2_mask/research_full}"' in script
    assert "find_stage4_checkpoint" in script
    assert "best.pth" in script
    assert "last.pth" in script
    assert "xargs -r -0 ls -t" in script
    assert "ann_file: ${CLEAN_DATASET_ROOT}/annotations/test.json" in script
    assert "tools/train.py" in script
    assert '-c "${CONFIG_PATH}"' in script
    assert "--test-only" in script
    assert "tools/export_onnx.py" in script
    assert "--check" in script
    assert "--onnx-export-log" in script
    assert "${OUTPUT_ROOT}/onnx_export.log" in script
    assert "food_rtdetrv2_r101_800px_clean.onnx" in script
    assert "product_manifest.json" in script
    assert "sha256" in script
    assert "MODEL_CARD.md" in script
    assert "--model-card" in script
    assert "scripts.training.food_rtdetr_product_manifest" in script
    assert "--test-annotation" in script
    assert "${CLEAN_DATASET_ROOT}/annotations/test.json" in script
    assert "--bundle-meta-dir" in script
    assert "--source-map" in script
    assert "--license-risk" in script
    assert "--pseudo-label-score" in script
    assert "--labels-json" in script
    assert "labels.json" in script
    assert "scripts.training.food_rtdetr_product_verify" in script
    assert "product_verification.json" in script


def test_product_manifest_builder_records_metrics_dataset_and_inference_policy(tmp_path: Path) -> None:
    from scripts.training.food_rtdetr_product_manifest import build_product_manifest

    checkpoint = tmp_path / "best.pth"
    onnx = tmp_path / "food_rtdetrv2_r101_800px_clean.onnx"
    config = tmp_path / "clean_test.yml"
    eval_log = tmp_path / "clean_test_eval.log"
    onnx_export_log = tmp_path / "onnx_export.log"
    eval_pth = tmp_path / "eval.pth"
    class_map = tmp_path / "class_map_v1.csv"
    source_counts = tmp_path / "source_counts.csv"
    source_map = tmp_path / "source_map.csv"
    license_risk = tmp_path / "license_risk.csv"
    pseudo_label_score = tmp_path / "pseudo_label_score.csv"
    test_annotation = tmp_path / "test.json"
    output_path = tmp_path / "product_manifest.json"
    bundle_meta_dir = tmp_path / "bundle" / "meta"
    labels_json = tmp_path / "bundle" / "labels.json"
    model_card = tmp_path / "bundle" / "MODEL_CARD.md"

    checkpoint.write_bytes(b"checkpoint")
    onnx.write_bytes(b"onnx")
    config.write_text("num_classes: 163\n", encoding="utf-8")
    eval_pth.write_bytes(b"eval")
    class_map.write_text("category_id,canonical_label\n1,炒饭\n", encoding="utf-8")
    source_counts.write_text("source_dataset,count\nUECFOOD-256,31645\n", encoding="utf-8")
    source_map.write_text("source_dataset,license_risk\nUECFOOD-256,needs_license_review\n", encoding="utf-8")
    license_risk.write_text("license_risk,allow_commercial_candidate\nresearch_only,no\n", encoding="utf-8")
    pseudo_label_score.write_text("bbox_type,min_score\npseudo_single_label,0.6\n", encoding="utf-8")
    test_annotation.write_text(
        json.dumps(
            {
                "images": [{"id": 1}, {"id": 2}],
                "annotations": [{"id": 1, "image_id": 1}, {"id": 2, "image_id": 2}, {"id": 3, "image_id": 2}],
                "categories": [{"id": 1, "name": "炒饭"}, {"id": 2, "name": "奶茶"}],
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )
    eval_log.write_text(
        "\n".join(
            [
                "Average Precision  (AP) @[ IoU=0.50:0.95 | area=   all | maxDets=100 ] = 0.456",
                "Average Precision  (AP) @[ IoU=0.50      | area=   all | maxDets=100 ] = 0.789",
                "Average Precision  (AP) @[ IoU=0.75      | area=   all | maxDets=100 ] = 0.654",
                "Average Recall     (AR) @[ IoU=0.50:0.95 | area=   all | maxDets=100 ] = 0.912",
            ]
        ),
        encoding="utf-8",
    )
    onnx_export_log.write_text("ONNX export check passed\n", encoding="utf-8")

    manifest = build_product_manifest(
        model="RT-DETRv2 R101",
        input_size=800,
        checkpoint=checkpoint,
        onnx=onnx,
        clean_test_config=config,
        clean_test_eval_log=eval_log,
        onnx_export_log=onnx_export_log,
        eval_pth=eval_pth,
        class_map=class_map,
        source_counts=source_counts,
        source_map=source_map,
        license_risk=license_risk,
        pseudo_label_score=pseudo_label_score,
        test_annotation=test_annotation,
        bundle_meta_dir=bundle_meta_dir,
        labels_json=labels_json,
        model_card=model_card,
        output_path=output_path,
    )

    assert manifest["metrics"]["coco_eval_bbox"]["ap"] == 0.456
    assert manifest["metrics"]["coco_eval_bbox"]["ap50"] == 0.789
    assert manifest["metrics"]["coco_eval_bbox"]["ap75"] == 0.654
    assert manifest["metrics"]["coco_eval_bbox"]["ar100"] == 0.912
    assert manifest["dataset"]["clean_test"] == {"images": 2, "annotations": 3, "categories": 2}
    assert manifest["inference_policy"]["accept_confidence"] == 0.75
    assert manifest["inference_policy"]["review_confidence_range"] == [0.45, 0.75]
    assert manifest["checkpoint_sha256"]
    assert manifest["onnx_sha256"]
    assert manifest["onnx_export_log"] == str(onnx_export_log)
    assert (bundle_meta_dir / "class_map_v1.csv").read_text(encoding="utf-8") == class_map.read_text(encoding="utf-8")
    assert (bundle_meta_dir / "source_counts.csv").read_text(encoding="utf-8") == source_counts.read_text(encoding="utf-8")
    assert (bundle_meta_dir / "source_map.csv").read_text(encoding="utf-8") == source_map.read_text(encoding="utf-8")
    assert (bundle_meta_dir / "license_risk.csv").read_text(encoding="utf-8") == license_risk.read_text(encoding="utf-8")
    assert (bundle_meta_dir / "pseudo_label_score.csv").read_text(encoding="utf-8") == pseudo_label_score.read_text(encoding="utf-8")
    assert manifest["metadata_files"]["class_map"]["bundle_path"] == str(bundle_meta_dir / "class_map_v1.csv")
    assert manifest["metadata_files"]["source_counts"]["sha256"]
    assert manifest["metadata_files"]["license_risk"]["bytes"] > 0
    labels = json.loads(labels_json.read_text(encoding="utf-8"))
    assert labels["num_classes"] == 1
    assert labels["category_id_to_label"]["1"] == "炒饭"
    assert labels["model_index_to_label"]["0"] == "炒饭"
    assert manifest["labels"]["path"] == str(labels_json)
    assert manifest["labels"]["sha256"]
    model_card_text = model_card.read_text(encoding="utf-8")
    assert "RT-DETRv2 R101" in model_card_text
    assert "AP50" in model_card_text
    assert "labels.json" in model_card_text
    assert manifest["model_card"]["path"] == str(model_card)
    assert manifest["model_card"]["sha256"]
    assert json.loads(output_path.read_text(encoding="utf-8")) == manifest


def test_product_verifier_accepts_complete_bundle_and_records_checks(tmp_path: Path) -> None:
    from scripts.training.food_rtdetr_product_manifest import build_product_manifest
    from scripts.training.food_rtdetr_product_verify import verify_product_bundle

    checkpoint = tmp_path / "best.pth"
    onnx = tmp_path / "food_rtdetrv2_r101_800px_clean.onnx"
    config = tmp_path / "clean_test.yml"
    eval_log = tmp_path / "clean_test_eval.log"
    onnx_export_log = tmp_path / "onnx_export.log"
    eval_pth = tmp_path / "eval.pth"
    class_map = tmp_path / "class_map_v1.csv"
    source_counts = tmp_path / "source_counts.csv"
    source_map = tmp_path / "source_map.csv"
    license_risk = tmp_path / "license_risk.csv"
    pseudo_label_score = tmp_path / "pseudo_label_score.csv"
    test_annotation = tmp_path / "test.json"
    manifest_path = tmp_path / "product" / "product_manifest.json"
    report_path = tmp_path / "product" / "product_verification.json"
    bundle_meta_dir = tmp_path / "product" / "meta"
    labels_json = tmp_path / "product" / "labels.json"
    model_card = tmp_path / "product" / "MODEL_CARD.md"

    checkpoint.write_bytes(b"checkpoint")
    onnx.write_bytes(b"onnx")
    config.write_text("num_classes: 163\n", encoding="utf-8")
    eval_pth.write_bytes(b"eval")
    class_map.write_text("category_id,canonical_label\n1,炒饭\n", encoding="utf-8")
    source_counts.write_text("source_dataset,count\nUECFOOD-256,31645\n", encoding="utf-8")
    source_map.write_text("source_dataset,license_risk\nUECFOOD-256,needs_license_review\n", encoding="utf-8")
    license_risk.write_text("license_risk,allow_commercial_candidate\nresearch_only,no\n", encoding="utf-8")
    pseudo_label_score.write_text("bbox_type,min_score\npseudo_single_label,0.6\n", encoding="utf-8")
    test_annotation.write_text(
        json.dumps(
            {
                "images": [{"id": 1}, {"id": 2}],
                "annotations": [{"id": 1}, {"id": 2}, {"id": 3}],
                "categories": [{"id": 1}, {"id": 2}],
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )
    eval_log.write_text(
        "\n".join(
            [
                "Average Precision  (AP) @[ IoU=0.50:0.95 | area=   all | maxDets=100 ] = 0.456",
                "Average Precision  (AP) @[ IoU=0.50      | area=   all | maxDets=100 ] = 0.789",
                "Average Precision  (AP) @[ IoU=0.75      | area=   all | maxDets=100 ] = 0.654",
                "Average Recall     (AR) @[ IoU=0.50:0.95 | area=   all | maxDets=100 ] = 0.912",
            ]
        ),
        encoding="utf-8",
    )
    onnx_export_log.write_text("ONNX export check passed\n", encoding="utf-8")
    build_product_manifest(
        model="RT-DETRv2 R101",
        input_size=800,
        checkpoint=checkpoint,
        onnx=onnx,
        clean_test_config=config,
        clean_test_eval_log=eval_log,
        onnx_export_log=onnx_export_log,
        eval_pth=eval_pth,
        class_map=class_map,
        source_counts=source_counts,
        source_map=source_map,
        license_risk=license_risk,
        pseudo_label_score=pseudo_label_score,
        test_annotation=test_annotation,
        bundle_meta_dir=bundle_meta_dir,
        labels_json=labels_json,
        model_card=model_card,
        output_path=manifest_path,
    )

    report = verify_product_bundle(manifest_path=manifest_path, output_path=report_path)

    assert report["ok"] is True
    assert report["summary"]["checked_count"] >= 10
    assert report["summary"]["failed_count"] == 0
    assert "metrics.coco_eval_bbox.ap50" in report["checks"]
    assert report["checks"]["onnx_export_log.file"]["ok"] is True
    assert report["checks"]["model_card.file"]["ok"] is True
    assert report["checks"]["metadata_files.class_map.bundle_sha256"]["ok"] is True
    assert report["checks"]["labels.file"]["ok"] is True
    assert json.loads(report_path.read_text(encoding="utf-8")) == report


def test_stage5_watch_script_waits_for_stage4_completion_before_eval_export() -> None:
    script = Path("scripts/training/remote_food_rtdetr_stage5_after_stage4_watch.sh").read_text(encoding="utf-8")

    assert 'STAGE4_SCREEN="${STAGE4_SCREEN:-stage4_clean_finetune}"' in script
    assert 'STAGE4_LOG="${STAGE4_LOG:-${STAGE4_WORK_ROOT}/logs/stage4_clean_finetune.log}"' in script
    assert 'STAGE5_SCRIPT="${STAGE5_SCRIPT:-/root/autodl-tmp/cal-repro/scripts/training/remote_food_rtdetr_stage5_eval_export.sh}"' in script
    assert 'MODEL_CONFIG_NAME="${MODEL_CONFIG_NAME:-rtdetrv2_r101vd_6x_coco}"' in script
    assert 'MODEL_DISPLAY_NAME="${MODEL_DISPLAY_NAME:-RT-DETRv2 R101}"' in script
    assert 'WORK_ROOT="${WORK_ROOT:-/root/autodl-tmp/food_rtdetr_stage5_product}"' in script
    assert 'STAGE5_SCREEN_LOG="${STAGE5_SCREEN_LOG:-${WORK_ROOT}/stage5_eval_export.screen.log}"' in script
    assert "Training time" in script
    assert "CUDA out of memory" in script
    assert "device-side assert" in script
    assert "stage5_eval_export" in script
    assert 'MODEL_CONFIG_NAME=\'${MODEL_CONFIG_NAME}\'' in script
    assert 'MODEL_DISPLAY_NAME=\'${MODEL_DISPLAY_NAME}\'' in script
    assert 'OUTPUT_ROOT=\'${OUTPUT_ROOT}\'' in script
    assert 'ONNX_OUTPUT=\'${ONNX_OUTPUT}\'' in script
    assert '>\\"${STAGE5_SCREEN_LOG}\\" 2>&1' in script
    assert 'START_STAGE5="${START_STAGE5:-1}"' in script
    assert 'while true; do' in script
    assert 'MODE="${1:-loop}"' in script


def test_stage3_stall_watch_parses_latest_progress_and_failures() -> None:
    from scripts.training.food_rtdetr_stage3_stall_watch import parse_train_log_text

    text = "\n".join(
        [
            "Epoch: [0]  [  120/30593]  eta: 5:10:00  lr: 0.000001  loss: 20.5000 (31.2500)",
            "RuntimeError: synthetic failure",
            "Epoch: [0]  [  140/30593]  eta: 5:09:42  lr: 0.000001  loss: 18.0000 (30.7500)",
        ]
    )

    latest, failures = parse_train_log_text(text)

    assert latest == {"epoch": 0, "iteration": 140, "total": 30593, "loss": 18.0, "loss_avg": 30.75}
    assert failures == ["RuntimeError: synthetic failure"]


def test_stage3_stall_watch_marks_suspect_after_consecutive_unchanged_checks() -> None:
    from scripts.training.food_rtdetr_stage3_stall_watch import build_stall_record

    latest = {"epoch": 0, "iteration": 140, "total": 30593, "loss": 18.0, "loss_avg": 30.75}

    record, key, stagnant = build_stall_record(
        latest=latest,
        failure_count=0,
        previous_key=(0, 140),
        stagnant_checks=2,
        threshold=3,
    )

    assert key == (0, 140)
    assert stagnant == 3
    assert record["status"] == "stalled_suspect"
    assert record["latest"] == latest


def test_try_images_loads_class_map_and_formats_predictions(tmp_path: Path) -> None:
    from scripts.training.food_rtdetr_try_images import format_predictions, load_model_index_labels

    class_map = tmp_path / "class_map_v1.csv"
    class_map.write_text(
        "category_id,canonical_label\n1,炒饭\n2,牛肉面\n162,未知饮品\n",
        encoding="utf-8",
    )

    labels = load_model_index_labels(class_map)
    predictions = format_predictions(
        labels=[161, 0, 1],
        boxes=[
            [10.1111, 20.2222, 30.3333, 40.4444],
            [1.2345, 2.3456, 9.8765, 10.9876],
            [5.0, 6.0, 7.0, 8.0],
        ],
        scores=[0.2, 0.81234, 0.55],
        label_map=labels,
        threshold=0.25,
        limit=10,
    )

    assert labels[0] == "炒饭"
    assert labels[161] == "未知饮品"
    assert predictions == [
        {"rank": 1, "label_index": 0, "label": "炒饭", "score": 0.8123, "bbox_xyxy": [1.23, 2.35, 9.88, 10.99]},
        {"rank": 2, "label_index": 1, "label": "牛肉面", "score": 0.55, "bbox_xyxy": [5.0, 6.0, 7.0, 8.0]},
    ]


def test_try_images_filters_overlapping_qa_predictions_with_nms() -> None:
    from scripts.training.food_rtdetr_try_images import format_predictions

    predictions = format_predictions(
        labels=[0, 1, 2, 3],
        boxes=[
            [0, 0, 100, 100],
            [4, 4, 104, 104],
            [160, 160, 240, 240],
            [300, 300, 340, 340],
        ],
        scores=[0.91, 0.89, 0.72, 0.2],
        label_map={0: "炒饭", 1: "主食", 2: "牛肉面", 3: "饮品"},
        threshold=0.25,
        limit=10,
        nms_iou_threshold=0.5,
    )

    assert [(item["rank"], item["label"], item["score"]) for item in predictions] == [
        (1, "炒饭", 0.91),
        (2, "牛肉面", 0.72),
    ]


def test_try_images_shortens_montage_caption_for_long_image_names() -> None:
    from scripts.training.food_rtdetr_try_images import format_montage_caption

    caption = format_montage_caption(
        name="37d3d539b6003af32f052167ef34634c1038b62d.jpeg@f_auto.webp",
        top_prediction={"label": "未知西餐", "score": 0.6842},
        max_chars=36,
    )

    assert caption == "37d3d539b6003af... | 未知西餐 0.68"
    assert len(caption) <= 36


def test_try_images_composites_transparent_images_and_writes_artifacts(tmp_path: Path) -> None:
    from scripts.training.food_rtdetr_try_images import (
        draw_predictions,
        load_rgb_image,
        write_montage,
        write_prediction_summary,
    )

    rgba = Image.new("RGBA", (24, 16), (0, 0, 0, 0))
    rgba.putpixel((4, 4), (255, 0, 0, 255))
    image_path = tmp_path / "tray.png"
    rgba.save(image_path)

    rgb = load_rgb_image(image_path)
    assert rgb.mode == "RGB"
    assert rgb.getpixel((0, 0)) == (255, 255, 255)
    assert rgb.getpixel((4, 4)) == (255, 0, 0)

    predictions = [{"rank": 1, "label": "炒饭", "score": 0.91, "bbox_xyxy": [2, 2, 18, 12]}]
    rendered = tmp_path / "tray_pred.jpg"
    draw_predictions(rgb, predictions, rendered)
    assert rendered.exists()

    montage = tmp_path / "montage.jpg"
    write_montage([{"image": rendered, "name": "tray.png", "predictions": predictions}], montage)
    assert montage.exists()

    summary = tmp_path / "predictions.json"
    write_prediction_summary(
        output_path=summary,
        checkpoint=Path("/models/best.pth"),
        config=Path("/configs/food.yml"),
        class_map=Path("/meta/class_map_v1.csv"),
        input_size=800,
        threshold=0.25,
        device="cpu",
        items=[{"image": image_path, "rendered": rendered, "predictions": predictions}],
        montage=montage,
    )

    payload = json.loads(summary.read_text(encoding="utf-8"))
    assert payload["checkpoint"] == "/models/best.pth"
    assert payload["items"][0]["top_prediction"]["label"] == "炒饭"
    assert payload["montage"] == str(montage)


def test_try_images_cli_collects_inputs_and_options(tmp_path: Path) -> None:
    from scripts.training.food_rtdetr_try_images import build_arg_parser, collect_input_paths

    image_dir = tmp_path / "images"
    image_dir.mkdir()
    direct = tmp_path / "direct.webp"
    nested = image_dir / "nested.jpeg"
    ignored = image_dir / "notes.txt"
    direct.write_bytes(b"webp")
    nested.write_bytes(b"jpeg")
    ignored.write_text("ignore", encoding="utf-8")

    args = build_arg_parser().parse_args(
        [
            "--config",
            "/configs/food.yml",
            "--checkpoint",
            "/models/best.pth",
            "--class-map",
            "/meta/class_map_v1.csv",
            "--input",
            str(direct),
            "--input-dir",
            str(image_dir),
            "--output-dir",
            str(tmp_path / "out"),
            "--threshold",
            "0.33",
            "--input-size",
            "800",
            "--device",
            "cpu",
        ]
    )

    assert args.threshold == 0.33
    assert args.input_size == 800
    assert args.device == "cpu"
    assert collect_input_paths(args.input, args.input_dir) == [direct, nested]


def test_try_images_run_writes_rendered_images_montage_and_summary(tmp_path: Path) -> None:
    from scripts.training.food_rtdetr_try_images import run_try_images

    image_path = tmp_path / "plate.jpg"
    Image.new("RGB", (32, 24), (240, 240, 240)).save(image_path)
    class_map = tmp_path / "class_map_v1.csv"
    class_map.write_text("category_id,canonical_label\n1,炒饭\n", encoding="utf-8")

    def fake_predictor(image, *, input_size: int, device: str):
        assert image.size == (32, 24)
        assert input_size == 800
        assert device == "cpu"
        return [0], [[2, 3, 22, 18]], [0.91]

    summary_path = run_try_images(
        config=Path("/configs/food.yml"),
        checkpoint=Path("/models/best.pth"),
        class_map=class_map,
        input_paths=[image_path],
        output_dir=tmp_path / "out",
        threshold=0.25,
        input_size=800,
        device="cpu",
        max_predictions=20,
        montage_name="montage.jpg",
        summary_name="predictions.json",
        predictor=fake_predictor,
    )

    payload = json.loads(summary_path.read_text(encoding="utf-8"))
    assert summary_path == tmp_path / "out" / "predictions.json"
    assert (tmp_path / "out" / "plate_pred.jpg").exists()
    assert (tmp_path / "out" / "montage.jpg").exists()
    assert payload["items"][0]["top_prediction"]["label"] == "炒饭"


def test_try_images_main_accepts_predictor_factory_for_cli_smoke(tmp_path: Path) -> None:
    from scripts.training.food_rtdetr_try_images import main

    image_path = tmp_path / "plate.jpg"
    Image.new("RGB", (32, 24), (240, 240, 240)).save(image_path)
    class_map = tmp_path / "class_map_v1.csv"
    class_map.write_text("category_id,canonical_label\n1,炒饭\n", encoding="utf-8")

    def fake_factory(*, config: Path, checkpoint: Path):
        assert config == Path("/configs/food.yml")
        assert checkpoint == Path("/models/best.pth")

        def fake_predictor(image, *, input_size: int, device: str):
            return [0], [[2, 3, 22, 18]], [0.91]

        return fake_predictor

    summary_path = main(
        [
            "--config",
            "/configs/food.yml",
            "--checkpoint",
            "/models/best.pth",
            "--class-map",
            str(class_map),
            "--input",
            str(image_path),
            "--output-dir",
            str(tmp_path / "out"),
            "--summary-name",
            "predictions.json",
        ],
        predictor_factory=fake_factory,
    )

    assert summary_path == tmp_path / "out" / "predictions.json"
    assert json.loads(summary_path.read_text(encoding="utf-8"))["items"][0]["top_prediction"]["score"] == 0.91


def test_stage3_small_probe_script_prepares_r50m_safely() -> None:
    script = Path("scripts/training/remote_food_rtdetr_stage3_small_probe.sh").read_text(encoding="utf-8")

    assert 'MODEL_NAME="${MODEL_NAME:-rtdetrv2_r50vd_m_7x_coco}"' in script
    assert "rtdetrv2_r50vd_m_7x_coco_ema.pth" in script
    assert 'RUN_MODE="${1:-prepare}"' in script
    assert 'INPUT_SIZE="${INPUT_SIZE:-640}"' in script
    assert 'BATCH_SIZE="${BATCH_SIZE:-16}"' in script
    assert 'EPOCHES="${EPOCHES:-12}"' in script
    assert 'SESSION_NAME="${SESSION_NAME:-stage3_small_r50m_probe}"' in script
    assert 'ALLOW_CONCURRENT="${ALLOW_CONCURRENT:-0}"' in script
    assert 'DOWNLOAD_CONNECT_TIMEOUT="${DOWNLOAD_CONNECT_TIMEOUT:-20}"' in script
    assert 'DOWNLOAD_MAX_TIME="${DOWNLOAD_MAX_TIME:-600}"' in script
    assert 'MODEL_CKPT_MIN_BYTES="${MODEL_CKPT_MIN_BYTES:-100000000}"' in script
    assert "checkpoint too small" in script
    assert 'stat -c%s "${MODEL_CKPT}"' in script
    assert 'MODEL_CKPT_URLS="${MODEL_CKPT_URLS:-' in script
    assert "huggingface.co/ekky24/rtdetrv2_r50vd_m_7x_coco_ema" in script
    assert "hf-mirror.com/ekky24/rtdetrv2_r50vd_m_7x_coco_ema" in script
    assert "for url in ${MODEL_CKPT_URLS}; do" in script
    assert 'if download_one_checkpoint "${url}"; then' in script
    assert "stage3_full_train" in script
    assert "Refusing to start small probe while stage3_full_train is running" in script
    assert "--connect-timeout" in script
    assert "--max-time" in script
    assert 'timeout "${DOWNLOAD_MAX_TIME}" wget' in script
    assert '-O "${MODEL_CKPT}.tmp"' in script
    assert 'mv "${MODEL_CKPT}.tmp" "${MODEL_CKPT}"' in script
    assert "eval_spatial_size: [${INPUT_SIZE}, ${INPUT_SIZE}]" in script
    assert "total_batch_size: ${BATCH_SIZE}" in script
    assert "--use-amp" in script
    ensure_ready_body = script.split("ensure_ready() {", 1)[1].split("\n}", 1)[0]
    assert ensure_ready_body.index("write_config") < ensure_ready_body.index("download_checkpoint")


def test_stage3_switch_to_small_waits_for_epoch2_eval_before_starting_r50m() -> None:
    script = Path("scripts/training/remote_food_rtdetr_stage3_switch_to_small_after_eval.sh").read_text(encoding="utf-8")

    assert 'TARGET_EPOCH="${TARGET_EPOCH:-2}"' in script
    assert 'MODE="${1:-loop}"' in script
    assert 'STAGE3_SCREEN="${STAGE3_SCREEN:-stage3_full_train}"' in script
    assert 'SMALL_SCRIPT="${SMALL_SCRIPT:-/root/autodl-tmp/cal-repro/scripts/training/remote_food_rtdetr_stage3_small_probe.sh}"' in script
    assert 'R101_BEST="${R101_OUTPUT_DIR}/best.pth"' in script
    assert 'has_eval_epoch "${TARGET_EPOCH}"' in script
    assert "printf '{\"target_epoch\": %s}'" in script
    assert 'local extra="${2:-}"' in script
    assert 'if [[ -z "${extra}" ]]; then' in script
    assert "screen -S \"${STAGE3_SCREEN}\" -X quit" in script
    assert 'ALLOW_CONCURRENT=1 "${SMALL_SCRIPT}" start' in script
    assert "switch_to_small_started" in script
    assert "stage3_small_r50m_probe" in script


def test_stage4_and_stage5_scripts_support_model_config_overrides() -> None:
    stage4 = Path("scripts/training/remote_food_rtdetr_stage4_clean_finetune.sh").read_text(encoding="utf-8")
    stage5 = Path("scripts/training/remote_food_rtdetr_stage5_eval_export.sh").read_text(encoding="utf-8")

    assert 'MODEL_CONFIG_NAME="${MODEL_CONFIG_NAME:-rtdetrv2_r101vd_6x_coco}"' in stage4
    assert '${RTDETR_ROOT}/configs/rtdetrv2/${MODEL_CONFIG_NAME}.yml' in stage4
    assert 'MODEL_CONFIG_NAME="${MODEL_CONFIG_NAME:-rtdetrv2_r101vd_6x_coco}"' in stage5
    assert '${RTDETR_ROOT}/configs/rtdetrv2/${MODEL_CONFIG_NAME}.yml' in stage5
    assert 'MODEL_DISPLAY_NAME="${MODEL_DISPLAY_NAME:-RT-DETRv2 R101}"' in stage5
    assert '--model "${MODEL_DISPLAY_NAME}"' in stage5


def test_stage4_after_small_probe_watcher_uses_r50m_paths_and_overrides() -> None:
    script = Path("scripts/training/remote_food_rtdetr_stage4_after_stage3_small_watch.sh").read_text(encoding="utf-8")

    assert 'STAGE3_WORK_ROOT="${STAGE3_WORK_ROOT:-/root/autodl-tmp/food_rtdetr_stage3_small}"' in script
    assert 'STAGE3_SCREEN="${STAGE3_SCREEN:-stage3_small_r50m_probe}"' in script
    assert 'STAGE3_OUTPUT_DIR="${STAGE3_OUTPUT_DIR:-${STAGE3_WORK_ROOT}/output/rtdetrv2_r50vd_m_7x_coco_640px_12e}"' in script
    assert 'MODEL_CONFIG_NAME="${MODEL_CONFIG_NAME:-rtdetrv2_r50vd_m_7x_coco}"' in script
    assert 'MODEL_DISPLAY_NAME="${MODEL_DISPLAY_NAME:-RT-DETRv2 R50-M}"' in script
    assert 'INPUT_SIZE="${INPUT_SIZE:-640}"' in script
    assert 'BATCH_SIZE="${BATCH_SIZE:-16}"' in script
    assert 'NUM_WORKERS="${NUM_WORKERS:-2}"' in script
    assert 'STAGE4_SESSION="${STAGE4_SESSION:-stage4_clean_finetune_r50m}"' in script
    assert 'STAGE5_SESSION="${STAGE5_SESSION:-stage5_eval_export_r50m}"' in script
    assert 'MODEL_CONFIG_NAME="${MODEL_CONFIG_NAME}"' in script
    assert 'NUM_WORKERS="${NUM_WORKERS}"' in script
    assert '[[ -f "${STAGE3_LOG}" ]]' in script
    assert "R50-M stage3 has not started yet; waiting" in script


def test_try_after_checkpoint_watcher_runs_user_images_on_cpu_once_checkpoint_exists() -> None:
    script = Path("scripts/training/remote_food_rtdetr_try_after_checkpoint_watch.sh").read_text(encoding="utf-8")

    assert 'STAGE3_OUTPUT_DIR="${STAGE3_OUTPUT_DIR:-/root/autodl-tmp/food_rtdetr_stage3_small/output/rtdetrv2_r50vd_m_7x_coco_640px_12e}"' in script
    assert 'CONFIG_PATH="${CONFIG_PATH:-/root/autodl-tmp/food_rtdetr_stage3_small/configs/food_rtdetrv2_r50vd_m_7x_coco_640px_12e.yml}"' in script
    assert 'CLASS_MAP="${CLASS_MAP:-/root/autodl-tmp/food_rtdetr_stage3/research_stage3_no_copy/meta/class_map_v1.csv}"' in script
    assert 'INPUT_DIR="${INPUT_DIR:-/root/autodl-tmp/food_rtdetr_stage3_small/user_try_images}"' in script
    assert 'TRY_SCRIPT="${TRY_SCRIPT:-/root/autodl-tmp/cal-repro/scripts/training/food_rtdetr_try_images.py}"' in script
    assert 'CUDA_VISIBLE_DEVICES=""' in script
    assert '--device cpu' in script
    assert '--input-size "${INPUT_SIZE}"' in script
    assert '--input-dir "${INPUT_DIR}"' in script
    assert 'try_after_checkpoint_started' in script
    assert 'checkpoint_path' in script
    assert 'CHECKPOINT_STABLE_SECONDS="${CHECKPOINT_STABLE_SECONDS:-30}"' in script
    assert 'checkpoint_not_stable_yet' in script
    assert 'checkpoint_size' in script
    assert 'checkpoint_age_seconds' in script
