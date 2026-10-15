import json
from pathlib import Path

from PIL import Image


def write_source_sample(handle, image_path: Path, name: str, phrase: str, category: str, density: float) -> None:
    item = {
        "name_zh": name,
        "detector_phrase": phrase,
        "category": category,
        "liquid": category in {"soup", "drink"},
        "mixed_dish": category == "mixed_dish",
        "confidence": 0.9,
        "density_g_per_ml": density,
        "kcal100": 100,
        "p100": 1,
        "c100": 2,
        "f100": 3,
        "fi100": 0,
        "na100": 10,
    }
    row = {
        "messages": [
            {"role": "user", "content": "<image>\nold prompt"},
            {
                "role": "assistant",
                "content": json.dumps(
                    {"items": [item], "detector_prompt_en": phrase},
                    ensure_ascii=False,
                    separators=(",", ":"),
                ),
            },
        ],
        "images": [str(image_path)],
        "metadata": {"source": "unit"},
    }
    handle.write(json.dumps(row, ensure_ascii=False) + "\n")


def test_builds_multi_item_json_sft_with_collage_images(tmp_path: Path) -> None:
    from scripts.training.build_multi_item_json_sft_dataset import build_dataset

    source = tmp_path / "single.jsonl"
    image_dir = tmp_path / "source_images"
    image_dir.mkdir()
    foods = [
        ("米饭", "rice", "staple", 0.75, (255, 245, 210)),
        ("鸡肉", "chicken", "protein", 0.95, (210, 170, 120)),
        ("青菜", "vegetables", "vegetable", 0.65, (90, 170, 90)),
        ("汤", "soup", "soup", 1.0, (230, 220, 120)),
    ]
    with source.open("w", encoding="utf-8") as handle:
        for idx, (name, phrase, category, density, color) in enumerate(foods):
            image_path = image_dir / f"{idx}.jpg"
            Image.new("RGB", (96, 80), color).save(image_path)
            write_source_sample(handle, image_path, name, phrase, category, density)

    output = tmp_path / "multi.jsonl"
    collages = tmp_path / "collages"
    written = build_dataset(
        input_path=source,
        output_path=output,
        image_dir=collages,
        count=3,
        min_items=3,
        max_items=4,
        seed=7,
        canvas_size=512,
    )

    assert written == 3
    rows = [json.loads(line) for line in output.read_text(encoding="utf-8").splitlines()]
    assert len(rows) == 3
    item_counts = []
    for row in rows:
        assert row["images"]
        assert Path(row["images"][0]).exists()
        assert row["messages"][0]["content"].startswith("<image>")
        assistant = row["messages"][-1]["content"]
        assert assistant.startswith("{") and assistant.endswith("}")
        payload = json.loads(assistant)
        item_counts.append(len(payload["items"]))
        assert len(payload["items"]) >= 3
        assert len(payload["detector_prompt_en"].split(" . ")) == len(payload["items"])
        for item in payload["items"]:
            assert item["density_g_per_ml"] > 0
            assert item["name_zh"]
            assert item["detector_phrase"]
    assert max(item_counts) >= 4


def test_skips_generic_food_names(tmp_path: Path) -> None:
    from scripts.training.build_multi_item_json_sft_dataset import parse_source_row

    image_path = tmp_path / "generic.jpg"
    Image.new("RGB", (96, 80), (200, 160, 120)).save(image_path)
    item = {
        "name_zh": "食物",
        "detector_phrase": "carrot",
        "category": "mixed_dish",
        "liquid": False,
        "mixed_dish": True,
        "confidence": 0.8,
        "density_g_per_ml": 0.75,
        "kcal100": 40,
        "p100": 1,
        "c100": 9,
        "f100": 0,
        "fi100": 0,
        "na100": 0,
    }
    row = {
        "messages": [
            {"role": "user", "content": "<image>\nold prompt"},
            {"role": "assistant", "content": json.dumps({"items": [item], "detector_prompt_en": "carrot"}, ensure_ascii=False)},
        ],
        "images": [str(image_path)],
        "metadata": {"source": "unit"},
    }

    assert parse_source_row(row) is None


def test_prompt_bans_duplicate_items_and_count_padding() -> None:
    from scripts.training.build_multi_item_json_sft_dataset import PROMPT

    assert "同一个食物只能输出一次" in PROMPT
    assert "不要为了凑数量" in PROMPT
    assert "通常 1-8 项" in PROMPT


def test_choose_records_dedupes_by_name_and_detector_phrase() -> None:
    from scripts.training.build_multi_item_json_sft_dataset import choose_records
    import random

    records = [
        {"item": {"name_zh": "米饭", "detector_phrase": "rice"}},
        {"item": {"name_zh": "米饭", "detector_phrase": "steamed rice"}},
        {"item": {"name_zh": "鸡肉", "detector_phrase": "chicken"}},
        {"item": {"name_zh": "青菜", "detector_phrase": "rice"}},
        {"item": {"name_zh": "汤", "detector_phrase": "soup"}},
    ]

    selected = choose_records(records, random.Random(1), 4)
    names = [record["item"]["name_zh"] for record in selected]
    phrases = [record["item"]["detector_phrase"].lower() for record in selected]

    assert len(names) == len(set(names))
    assert len(phrases) == len(set(phrases))
    assert len(selected) == 4


def test_build_dataset_allows_single_item_samples(tmp_path: Path) -> None:
    from scripts.training.build_multi_item_json_sft_dataset import build_dataset

    source = tmp_path / "single.jsonl"
    image_dir = tmp_path / "source_images"
    image_dir.mkdir()
    foods = [
        ("米饭", "rice", "staple", 0.75, (255, 245, 210)),
        ("鸡肉", "chicken", "protein", 0.95, (210, 170, 120)),
    ]
    with source.open("w", encoding="utf-8") as handle:
        for idx, (name, phrase, category, density, color) in enumerate(foods):
            image_path = image_dir / f"{idx}.jpg"
            Image.new("RGB", (96, 80), color).save(image_path)
            write_source_sample(handle, image_path, name, phrase, category, density)

    output = tmp_path / "mixed.jsonl"
    collages = tmp_path / "collages"
    written = build_dataset(
        input_path=source,
        output_path=output,
        image_dir=collages,
        count=2,
        min_items=1,
        max_items=2,
        seed=9,
        canvas_size=256,
    )

    assert written == 2
    rows = [json.loads(line) for line in output.read_text(encoding="utf-8").splitlines()]
    counts = [len(json.loads(row["messages"][-1]["content"])["items"]) for row in rows]
    assert counts == [1, 2]
