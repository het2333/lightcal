import base64
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

from models.food import Food
from services.describe_meal import DescribeMealService
from services.food_database import FoodDatabase
from services.llm_providers import LLMProvider, MimoProvider


class FakePhotoProvider(LLMProvider):
    def __init__(self, detection_response: dict, review_response: dict | Exception):
        self.detection_response = detection_response
        self.review_response = review_response

    async def analyze_image(self, image_base64: str) -> str:
        return json.dumps({"foods": [], "description": ""}, ensure_ascii=False)

    async def analyze_text(self, description: str) -> str:
        return json.dumps({"foods": [], "description": ""}, ensure_ascii=False)

    async def analyze_image_with_prompt(
        self,
        image_base64: str,
        system_prompt: str,
        user_prompt: str,
        max_tokens: int = 2048,
    ) -> str:
        return json.dumps(self.detection_response, ensure_ascii=False)

    async def raw_completion(self, system_prompt: str, user_prompt: str, max_tokens: int = 2048) -> str:
        if isinstance(self.review_response, Exception):
            raise self.review_response
        return json.dumps(self.review_response, ensure_ascii=False)


class CapturingPhotoProvider(FakePhotoProvider):
    def __init__(self, detection_response: dict, review_response: dict | Exception):
        super().__init__(detection_response, review_response)
        self.image_prompts: list[str] = []

    async def analyze_image_with_prompt(
        self,
        image_base64: str,
        system_prompt: str,
        user_prompt: str,
        max_tokens: int = 2048,
    ) -> str:
        self.image_prompts.append(user_prompt)
        return await super().analyze_image_with_prompt(image_base64, system_prompt, user_prompt, max_tokens)


class FailingPhotoProvider(LLMProvider):
    async def analyze_image(self, image_base64: str) -> str:
        return json.dumps({"foods": [], "description": ""}, ensure_ascii=False)

    async def analyze_text(self, description: str) -> str:
        return json.dumps({"foods": [], "description": ""}, ensure_ascii=False)

    async def analyze_image_with_prompt(
        self,
        image_base64: str,
        system_prompt: str,
        user_prompt: str,
        max_tokens: int = 2048,
    ) -> str:
        raise RuntimeError("MiMo API error: ConnectError: ConnectError('')")


class InvalidKeyPhotoProvider(FailingPhotoProvider):
    async def analyze_image_with_prompt(
        self,
        image_base64: str,
        system_prompt: str,
        user_prompt: str,
        max_tokens: int = 2048,
    ) -> str:
        raise RuntimeError("MiMo API error: Invalid API Key")


def tiny_base64() -> str:
    return (
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8"
        "/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
    )


class FakeMimoResponse:
    status_code = 200

    def json(self) -> dict:
        return {"choices": [{"message": {"content": "ok"}}]}


class CapturingAsyncClient:
    captured_kwargs: list[dict] = []

    def __init__(self, *args, **kwargs):
        self.captured_kwargs.append(kwargs)

    async def __aenter__(self):
        return self

    async def __aexit__(self, exc_type, exc, tb):
        return False

    async def post(self, *args, **kwargs):
        return FakeMimoResponse()


def make_food_db(tmp_path: Path) -> FoodDatabase:
    return FoodDatabase(tmp_path / "foods.db")


def create_foods_clean(food_db: FoodDatabase) -> None:
    with food_db._get_conn() as conn:
        conn.execute(
            """
            CREATE TABLE foods_clean AS
            SELECT *, lower(trim(name)) AS normalized_name
            FROM foods
            WHERE 0
            """
        )
        conn.execute(
            """
            INSERT INTO foods_clean
                (id, name, calories, protein, carbs, fat, fiber, sugar, added_sugar,
                 sodium, sat_fat, trans_fat, cholesterol, vitamin_a, vitamin_c,
                 calcium, iron, potassium, serving_size, processing_level, barcode,
                 source, created_at, normalized_name)
            VALUES
                ('rice_cn', '米饭（蒸，代表值）', 116, 2.6, 25.9, 0.3, 0.3, 0.1, 0,
                 1, 0.1, 0, 0, 0, 0, 3, 0.2, 29, '100g', 'minimally_processed', '',
                 '中国食物成分表', CURRENT_DATE, '米饭（蒸，代表值）'),
                ('rice_brand', '包装米饭', 138, 2.3, 31.9, 0, 0, 0, 0,
                 10, 0, 0, 0, 0, 0, 0, 0, 0, '200 g', 'processed', '',
                 'Open Food Facts full product dump', CURRENT_DATE, '包装米饭'),
                ('celery_bad', '西洋芹菜片', 315.4, 24.4, 49.9, 6.8, 23.4, 14.6, 0,
                 91, 1.3, 0, 0, 1122, 27.8, 1149, 19.7, 5195, '每100克可食部分', 'whole', '',
                 '台湾食品营养成分资料库 2025 UPDATE1', CURRENT_DATE, '西洋芹菜片'),
                ('celery_good', '西洋芹菜', 11.2, 0.4, 2.2, 0.2, 1.6, 1.2, 0,
                 30, 0, 0, 0, 0, 3, 40, 0.2, 260, '每100克可食部分', 'whole', '',
                 '台湾食品营养成分资料库 2025 UPDATE1', CURRENT_DATE, '西洋芹菜'),
                ('pepper_good', '青椒', 22, 1, 5.4, 0.2, 1.4, 2.3, 0,
                 3, 0, 0, 0, 0, 80, 10, 0.4, 175, '100g', 'whole', '',
                 'cleaned_merged', CURRENT_DATE, '青椒')
            """
        )
        conn.commit()


@pytest.fixture(autouse=True)
def isolate_default_photo_analysis_mode(monkeypatch):
    """Keep two-pass tests independent from the developer's local .env mode."""
    monkeypatch.setenv("PHOTO_ANALYSIS_MODE", "two_pass")


@pytest.mark.asyncio
async def test_mimo_provider_ignores_system_proxy_by_default(monkeypatch):
    CapturingAsyncClient.captured_kwargs = []
    monkeypatch.delenv("MIMO_TRUST_ENV", raising=False)
    monkeypatch.setattr("services.llm_providers.httpx.AsyncClient", CapturingAsyncClient)

    provider = MimoProvider("test-key")
    assert await provider.raw_completion("system", "user") == "ok"

    assert CapturingAsyncClient.captured_kwargs
    assert CapturingAsyncClient.captured_kwargs[0]["trust_env"] is False


@pytest.mark.asyncio
async def test_mimo_provider_can_opt_into_env_proxy(monkeypatch):
    CapturingAsyncClient.captured_kwargs = []
    monkeypatch.setenv("MIMO_TRUST_ENV", "true")
    monkeypatch.setattr("services.llm_providers.httpx.AsyncClient", CapturingAsyncClient)

    provider = MimoProvider("test-key")
    assert await provider.raw_completion("system", "user") == "ok"

    assert CapturingAsyncClient.captured_kwargs
    assert CapturingAsyncClient.captured_kwargs[0]["trust_env"] is True


@pytest.mark.asyncio
async def test_photo_pipeline_does_not_truncate_to_six(tmp_path):
    detection_items = [
        {
            "name": f"食物{i}",
            "estimated_grams": 20 + i,
            "quantity": 1,
            "unit": "份",
            "cooking_method": "不确定",
            "is_mixed_dish": False,
            "visible_confidence": 0.8,
        }
        for i in range(8)
    ]
    review_foods = [
        {
            "name": f"食物{i}",
            "calories": 30 + i,
            "protein": 1,
            "carbs": 5,
            "fat": 1,
            "fiber": 0,
            "sugar": 0,
            "added_sugar": 0,
            "sodium": 10,
            "serving_size": f"{20 + i}克",
            "processing_level": "whole",
        }
        for i in range(8)
    ]
    provider = FakePhotoProvider(
        {"items": detection_items, "description": "多食物餐盘"},
        {"foods": review_foods, "description": "复核完成"},
    )

    service = DescribeMealService(provider=provider, food_db=make_food_db(tmp_path))
    foods, description, metadata = await service._analyze_image(tiny_base64())

    assert len(foods) == 8
    assert description == "复核完成"
    assert metadata is not None


@pytest.mark.asyncio
async def test_photo_pipeline_direct_nutrition_mode_skips_review(monkeypatch, tmp_path):
    monkeypatch.setenv("PHOTO_ANALYSIS_MODE", "direct_nutrition")
    provider = FakePhotoProvider(
        {
            "foods": [
                {
                    "n": "炸鸡块",
                    "g": 87,
                    "q": "约3块",
                    "m": "炸",
                    "conf": 0.91,
                    "kcal": 246,
                    "p": 15,
                    "c": 13,
                    "f": 15,
                    "fi": 1,
                    "na": 520,
                    "pl": "processed",
                }
            ],
            "d": "识别到炸鸡块。",
        },
        RuntimeError("review should not be called"),
    )

    service = DescribeMealService(provider=provider, food_db=make_food_db(tmp_path))
    foods, description, metadata = await service._analyze_image(tiny_base64())

    assert len(foods) == 1
    assert foods[0].name == "炸鸡块"
    assert foods[0].serving_size == "87克"
    assert foods[0].calories == pytest.approx(243.6, abs=0.1)
    assert foods[0].protein == pytest.approx(13.1, abs=0.1)
    assert foods[0].carbs == pytest.approx(10.4, abs=0.1)
    assert foods[0].fat == pytest.approx(15.7, abs=0.1)
    assert foods[0].fiber == pytest.approx(0.9, abs=0.1)
    assert foods[0].sodium == pytest.approx(522, abs=0.1)
    assert description == "识别到炸鸡块。"
    assert metadata["strategy"] == "direct_image_nutrition"
    assert metadata["items"][0]["quantity"] == "约3块"
    assert metadata["items"][0]["cooking_method"] == "炸"
    assert metadata["items"][0]["model_confidence"] == pytest.approx(0.91)
    assert metadata["items"][0]["model_direct_nutrition"]["calories"] == 246


@pytest.mark.asyncio
async def test_photo_pipeline_passes_ios_depth_volume_context_to_model(monkeypatch, tmp_path):
    monkeypatch.setenv("PHOTO_ANALYSIS_MODE", "direct_nutrition")
    provider = CapturingPhotoProvider(
        {
            "foods": [
                {
                    "n": "紫米饭",
                    "g": 137,
                    "q": "约1碗",
                    "m": "蒸",
                    "conf": 0.86,
                    "kcal": 230,
                    "p": 4,
                    "c": 49,
                    "f": 1,
                    "fi": 3,
                    "na": 8,
                }
            ],
            "d": "识别到紫米饭。",
        },
        RuntimeError("review should not be called"),
    )
    capture_context = {
        "capture_metadata": {
            "source": "ios_camera",
            "has_depth": True,
            "image_width": 3024,
            "image_height": 4032,
        },
        "depth_metadata": {
            "available": True,
            "mean_depth_m": 0.42,
            "roi_mean_depth_m": 0.38,
            "background_depth_m": 0.46,
            "foreground_area_ratio": 0.41,
            "mean_foreground_height_m": 0.05,
            "max_foreground_height_m": 0.09,
            "relative_volume_proxy": 1832.5,
            "valid_sample_count": 1200,
            "volume_method": "center_roi_depth_foreground_proxy",
        },
    }

    service = DescribeMealService(provider=provider, food_db=make_food_db(tmp_path))
    foods, _, metadata = await service._analyze_image(tiny_base64(), capture_context=capture_context)

    assert foods[0].serving_size == "137克"
    assert metadata["capture_context_used"] is True
    assert provider.image_prompts
    prompt = provider.image_prompts[0]
    assert "额外拍摄/深度/体积信息" in prompt
    assert "foreground_area_ratio=0.41" in prompt
    assert "relative_volume_proxy=1832.5" in prompt


@pytest.mark.asyncio
async def test_photo_pipeline_without_depth_uses_monocular_portion_prompt(monkeypatch, tmp_path):
    monkeypatch.setenv("PHOTO_ANALYSIS_MODE", "direct_nutrition")
    provider = CapturingPhotoProvider(
        {
            "foods": [
                {
                    "n": "炒面",
                    "g": 213,
                    "q": "约一碗",
                    "m": "炒",
                    "conf": 0.78,
                    "kcal": 420,
                    "p": 13,
                    "c": 60,
                    "f": 14,
                    "fi": 4,
                    "na": 760,
                }
            ],
            "d": "识别到炒面。",
        },
        RuntimeError("review should not be called"),
    )
    capture_context = {
        "capture_metadata": {
            "source": "photo_library",
            "has_depth": False,
            "image_width": 3024,
            "image_height": 4032,
        },
        "depth_metadata": {},
    }

    service = DescribeMealService(provider=provider, food_db=make_food_db(tmp_path))
    foods, _, metadata = await service._analyze_image(tiny_base64(), capture_context=capture_context)

    assert foods[0].serving_size == "213克"
    assert metadata["capture_context_used"] is True
    prompt = provider.image_prompts[0]
    assert "has_depth=False" in prompt
    assert "当前没有可靠 depth/体积数据" in prompt
    assert "单目图片估重 fallback" in prompt
    assert "餐盘/碗/杯/餐盒" in prompt
    assert "2D面积占比" in prompt
    assert "禁止默认100克" in prompt


@pytest.mark.asyncio
async def test_photo_pipeline_fast_db_mode_uses_visual_grams_and_database(monkeypatch, tmp_path):
    monkeypatch.setenv("PHOTO_ANALYSIS_MODE", "fast_db")
    food_db = make_food_db(tmp_path)
    create_foods_clean(food_db)
    provider = FakePhotoProvider(
        {
            "foods": [
                {"n": "米饭", "g": 150, "m": "蒸", "conf": 0.9},
            ],
            "d": "识别到米饭。",
        },
        RuntimeError("review should not be called"),
    )

    service = DescribeMealService(provider=provider, food_db=food_db)
    foods, description, metadata = await service._analyze_image(tiny_base64())

    assert len(foods) == 1
    assert foods[0].name == "米饭（蒸，代表值）"
    assert foods[0].serving_size == "150克"
    assert foods[0].calories == pytest.approx(174, abs=0.1)
    assert description == "识别到米饭。"
    assert metadata["strategy"] == "vision_fast_db_nutrition"
    assert metadata["items"][0]["nutrition_source"] == "database_exact_fast"


@pytest.mark.asyncio
async def test_photo_pipeline_direct_db_mode_overrides_strong_database_match(monkeypatch, tmp_path):
    monkeypatch.setenv("PHOTO_ANALYSIS_MODE", "direct_db")
    food_db = make_food_db(tmp_path)
    create_foods_clean(food_db)
    provider = FakePhotoProvider(
        {
            "foods": [
                {
                    "n": "米饭",
                    "g": 150,
                    "q": "约1碗",
                    "m": "蒸",
                    "conf": 0.92,
                    "kcal": 999,
                    "p": 1,
                    "c": 1,
                    "f": 1,
                    "fi": 0,
                    "na": 0,
                    "pl": "whole",
                }
            ],
            "d": "识别到米饭。",
        },
        RuntimeError("review should not be called"),
    )

    service = DescribeMealService(provider=provider, food_db=food_db)
    foods, description, metadata = await service._analyze_image(tiny_base64())

    assert len(foods) == 1
    assert foods[0].name == "米饭（蒸，代表值）"
    assert foods[0].serving_size == "150克"
    assert foods[0].calories == pytest.approx(174, abs=0.1)
    assert description == "识别到米饭。"
    assert metadata["strategy"] == "direct_model_db_override"
    assert metadata["database_override_count"] == 1
    assert metadata["items"][0]["nutrition_source"] == "database_strong_match"
    assert metadata["items"][0]["model_original"]["calories"] == 999
    assert metadata["items"][0]["quantity"] == "约1碗"
    assert metadata["items"][0]["cooking_method"] == "蒸"
    assert metadata["items"][0]["model_confidence"] == pytest.approx(0.92)
    assert metadata["items"][0]["model_direct_nutrition"]["calories"] == 999


def test_direct_nutrition_repair_keeps_oil_macros_reasonable(tmp_path):
    service = DescribeMealService(provider=FakePhotoProvider({}, {}), food_db=make_food_db(tmp_path))
    foods = [
        Food(
            name="调味油",
            serving_size="50克",
            calories=400,
            protein=0,
            carbs=0,
            fat=5,
            fiber=0,
            sugar=0,
            sodium=0,
        )
    ]

    repaired = service._repair_direct_nutrition(foods)

    assert repaired[0].fat == pytest.approx(44.4, abs=0.1)


def test_direct_nutrition_repair_calibrates_common_fried_foods(tmp_path):
    service = DescribeMealService(provider=FakePhotoProvider({}, {}), food_db=make_food_db(tmp_path))
    foods = [
        Food(
            name="炸鸡块",
            serving_size="250克",
            calories=300,
            protein=20,
            carbs=15,
            fat=25,
            fiber=1,
            sugar=0,
            sodium=150,
        ),
        Food(
            name="薯条",
            serving_size="100克",
            calories=150,
            protein=2,
            carbs=18,
            fat=9,
            fiber=2,
            sugar=0,
            sodium=100,
        ),
    ]

    repaired = service._repair_direct_nutrition(foods)

    assert repaired[0].calories == pytest.approx(700, abs=0.1)
    assert repaired[0].fat == pytest.approx(45, abs=0.1)
    assert repaired[0].sodium == pytest.approx(1500, abs=0.1)
    assert repaired[1].calories == pytest.approx(312, abs=0.1)
    assert repaired[1].carbs == pytest.approx(41, abs=0.1)


def test_direct_db_rejects_known_food_database_calorie_outlier(tmp_path):
    food_db = make_food_db(tmp_path)
    create_foods_clean(food_db)
    with food_db._get_conn() as conn:
        conn.execute(
            """
            INSERT INTO foods_clean
                (id, name, calories, protein, carbs, fat, fiber, sugar, added_sugar,
                 sodium, sat_fat, trans_fat, cholesterol, vitamin_a, vitamin_c,
                 calcium, iron, potassium, serving_size, processing_level, barcode,
                 source, created_at, normalized_name)
            VALUES
                ('fried_chicken_outlier', '炸鸡块', 455, 25.7, 15.4, 31.6, 0.1, 1.1, 0.8,
                 627, 3.9, 0.4, 35, 39, 0, 9, 0.9, 121, '100g', 'processed', '',
                 'cleaned_merged', CURRENT_DATE, '炸鸡块')
            """
        )
        conn.commit()
    service = DescribeMealService(provider=FakePhotoProvider({}, {}), food_db=food_db)
    food = Food(
        name="炸鸡块",
        serving_size="120克",
        calories=999,
        protein=1,
        carbs=1,
        fat=1,
        fiber=0,
        sugar=0,
        sodium=0,
    )

    fixed, meta = service._override_direct_food_with_database(food)

    assert meta["nutrition_source"] == "local_density_profile_db_outlier"
    assert "database_per_100g_calories_outlier" in meta["db_reject_reason"]
    assert fixed.calories == pytest.approx(336, abs=0.1)
    assert fixed.fat == pytest.approx(21.6, abs=0.1)


@pytest.mark.asyncio
async def test_photo_pipeline_direct_db_does_not_force_merge_fried_chicken_items(monkeypatch, tmp_path):
    monkeypatch.setenv("PHOTO_ANALYSIS_MODE", "direct_db")
    provider = FakePhotoProvider(
        {
            "title": "油炸小食拼盘",
            "foods": [
                {"n": "炸鸡块", "g": 121, "q": "约3块", "m": "炸", "conf": 0.8, "kcal": 100, "p": 1, "c": 1, "f": 1, "fi": 0, "na": 0},
                {"n": "鸡米花", "g": 83, "q": "约1小堆", "m": "炸", "conf": 0.75, "kcal": 100, "p": 1, "c": 1, "f": 1, "fi": 0, "na": 0},
                {"n": "炸鸡柳", "g": 92, "q": "约2条", "m": "炸", "conf": 0.72, "kcal": 100, "p": 1, "c": 1, "f": 1, "fi": 0, "na": 0},
                {"n": "薯条", "g": 107, "q": "约1小份", "m": "炸", "conf": 0.82, "kcal": 100, "p": 1, "c": 1, "f": 1, "fi": 0, "na": 0},
            ],
            "d": "识别到油炸小食拼盘。",
        },
        RuntimeError("review should not be called"),
    )
    service = DescribeMealService(provider=provider, food_db=make_food_db(tmp_path))

    foods, description, metadata = await service._analyze_image(tiny_base64())

    assert [food.name for food in foods] == ["炸鸡块", "鸡米花", "炸鸡柳", "薯条"]
    assert [food.serving_size for food in foods] == ["121克", "83克", "92克", "107克"]
    assert foods[0].calories == pytest.approx(338.8, abs=0.1)
    assert foods[1].calories == pytest.approx(232.4, abs=0.1)
    assert foods[2].calories == pytest.approx(257.6, abs=0.1)
    assert foods[3].calories == pytest.approx(333.8, abs=0.1)
    assert all("dedupe_reason" not in item for item in metadata["items"])


@pytest.mark.asyncio
async def test_photo_pipeline_falls_back_to_foods_clean_candidate(tmp_path):
    food_db = make_food_db(tmp_path)
    create_foods_clean(food_db)
    provider = FakePhotoProvider(
        {
            "items": [{
                "name": "米饭",
                "estimated_grams": 150,
                "quantity": 1,
                "unit": "碗",
                "cooking_method": "蒸",
                "is_mixed_dish": False,
                "visible_confidence": 0.9,
            }],
            "description": "一碗米饭",
        },
        RuntimeError("review unavailable"),
    )

    service = DescribeMealService(provider=provider, food_db=food_db)
    foods, description, metadata = await service._analyze_image(tiny_base64())

    assert len(foods) == 1
    assert foods[0].name == "米饭（蒸，代表值）"
    assert foods[0].serving_size == "150克"
    assert foods[0].calories == pytest.approx(174, abs=0.1)
    assert metadata["items"][0]["nutrition_source"] == "database_candidate"


@pytest.mark.asyncio
async def test_photo_pipeline_uses_visual_grams_over_review_default_100g(tmp_path):
    provider = FakePhotoProvider(
        {
            "items": [
                {
                    "name": "紫甘蓝丝",
                    "estimated_grams": 80,
                    "quantity": 1,
                    "unit": "份",
                    "cooking_method": "生",
                    "is_mixed_dish": False,
                    "visible_confidence": 0.9,
                },
                {
                    "name": "青椒片",
                    "estimated_grams": 35,
                    "quantity": 1,
                    "unit": "份",
                    "cooking_method": "生",
                    "is_mixed_dish": False,
                    "visible_confidence": 0.8,
                },
            ],
            "description": "蔬菜拼盘",
        },
        {
            "foods": [
                {
                    "name": "紫甘蓝丝",
                    "calories": 25,
                    "protein": 1.5,
                    "carbs": 4,
                    "fat": 0.2,
                    "fiber": 2,
                    "sugar": 1,
                    "added_sugar": 0,
                    "sodium": 25,
                    "serving_size": "100克",
                    "processing_level": "whole",
                },
                {
                    "name": "青椒片",
                    "calories": 22,
                    "protein": 1,
                    "carbs": 5,
                    "fat": 0.2,
                    "fiber": 1.4,
                    "sugar": 2,
                    "added_sugar": 0,
                    "sodium": 3,
                    "serving_size": "100克",
                    "processing_level": "whole",
                },
            ],
            "description": "复核完成",
        },
    )

    service = DescribeMealService(provider=provider, food_db=make_food_db(tmp_path))
    foods, _, _ = await service._analyze_image(tiny_base64())

    assert [food.serving_size for food in foods] == ["80克", "35克"]
    assert foods[0].calories == pytest.approx(20, abs=0.1)
    assert foods[1].calories == pytest.approx(7.7, abs=0.1)


@pytest.mark.asyncio
async def test_photo_pipeline_accepts_strict_pass1_pass2_schema(tmp_path):
    provider = FakePhotoProvider(
        {
            "image_quality": {
                "visibility": "good",
                "angle": "top_down",
                "occlusion_level": "low",
                "note": "画面清楚",
            },
            "foods": [
                {
                    "pass1_id": "F1",
                    "name_zh": "西洋芹菜片",
                    "candidate_names": [{"name_zh": "西洋芹菜", "confidence": 0.8}],
                    "category": "蔬菜",
                    "location": "餐盘左侧",
                    "visible_form": "片状",
                    "quantity": {"count": 1, "unit": "份", "description": "少量一份"},
                    "estimated_grams": 37,
                    "estimated_grams_range": [28, 45],
                    "weight_basis": "按餐盘占比估计",
                    "cooking_method": "生食",
                    "is_mixed_dish": False,
                    "visible_components": [],
                    "confidence": 0.74,
                    "uncertainty_reason": "部分重叠",
                }
            ],
            "micro_seasonings": [],
            "coverage_check": {"major_visible_foods_covered": True},
        },
        {
            "foods": [
                {
                    "pass1_id": "F1",
                    "final_name_zh": "西洋芹菜片",
                    "category": "蔬菜",
                    "serving_size_grams": 37,
                    "pass1_estimated_grams": 37,
                    "serving_size_check": "must_equal_pass1_estimated_grams",
                    "source_type": "common_sense_estimate",
                    "source_id": None,
                    "source_name": "同类新鲜蔬菜",
                    "source_reason": "数据库候选热量异常，改用同类估算",
                    "match_confidence": 0.7,
                    "nutrition": {
                        "calories_kcal": 4.1,
                        "protein_g": 0.2,
                        "fat_g": 0.1,
                        "carbohydrate_g": 0.8,
                        "fiber_g": 0.6,
                        "sugar_g": 0.4,
                        "sodium_mg": 11,
                    },
                    "calculation_basis": "同类蔬菜每100克营养 × 估重37克",
                    "adjustments": [{"type": "数据库异常修正", "description": "未采用异常高热量候选"}],
                    "nutrition_uncertainty": "medium",
                }
            ],
            "coverage_check": {
                "pass1_food_ids": ["F1"],
                "covered_pass1_ids": ["F1"],
                "missing_pass1_ids": [],
                "invalid_default_100g_detected": False,
                "all_serving_sizes_equal_pass1": True,
            },
            "description": "复核完成",
        },
    )

    service = DescribeMealService(provider=provider, food_db=make_food_db(tmp_path))
    foods, description, _ = await service._analyze_image(tiny_base64())

    assert description == "复核完成"
    assert len(foods) == 1
    assert foods[0].name == "西洋芹菜片"
    assert foods[0].serving_size == "37克"
    assert foods[0].calories == pytest.approx(4.1, abs=0.1)
    assert foods[0].carbs == pytest.approx(0.8, abs=0.1)
    assert foods[0].quantity_count == 1
    assert foods[0].quantity_unit == "份"
    assert foods[0].quantity_description == "少量一份"


@pytest.mark.asyncio
async def test_photo_pipeline_repairs_zero_or_unreasonable_review_with_clean_candidate(tmp_path):
    food_db = make_food_db(tmp_path)
    create_foods_clean(food_db)
    provider = FakePhotoProvider(
        {
            "items": [
                {
                    "name": "青椒片",
                    "estimated_grams": 35,
                    "quantity": 1,
                    "unit": "份",
                    "cooking_method": "生",
                    "is_mixed_dish": False,
                    "visible_confidence": 0.9,
                }
            ],
            "description": "青椒片",
        },
        {
            "foods": [
                {
                    "name": "青椒片",
                    "calories": 0,
                    "protein": 0,
                    "carbs": 0,
                    "fat": 0,
                    "fiber": 0,
                    "sugar": 0,
                    "added_sugar": 0,
                    "sodium": 0,
                    "serving_size": "100克",
                    "processing_level": "whole",
                }
            ],
            "description": "复核失败但有候选",
        },
    )

    service = DescribeMealService(provider=provider, food_db=food_db)
    foods, _, _ = await service._analyze_image(tiny_base64())

    assert len(foods) == 1
    assert foods[0].serving_size == "35克"
    assert foods[0].calories == pytest.approx(7.7, abs=0.1)


@pytest.mark.asyncio
async def test_photo_pipeline_treats_database_as_reference_for_plain_tea(tmp_path):
    provider = FakePhotoProvider(
        {
            "items": [
                {
                    "name": "茶",
                    "estimated_grams": 150,
                    "quantity": 1,
                    "unit": "杯",
                    "cooking_method": "未知",
                    "is_mixed_dish": False,
                    "visible_confidence": 0.8,
                }
            ],
            "description": "一杯茶",
        },
        {
            "foods": [
                {
                    "name": "茶",
                    "calories": 1349,
                    "protein": 0,
                    "carbs": 92,
                    "fat": 170,
                    "fiber": 0,
                    "sugar": 4,
                    "added_sugar": 0,
                    "sodium": 1047,
                    "serving_size": "150克",
                    "processing_level": "whole",
                }
            ],
            "description": "复核完成",
        },
    )

    service = DescribeMealService(provider=provider, food_db=make_food_db(tmp_path))
    foods, _, _ = await service._analyze_image(tiny_base64())

    assert service._plain_low_calorie_liquid_profile("茶油") is None
    assert len(foods) == 1
    assert foods[0].name == "茶"
    assert foods[0].serving_size == "150克"
    assert foods[0].calories <= 3
    assert foods[0].carbs == 0
    assert foods[0].fat == 0


@pytest.mark.asyncio
async def test_photo_pipeline_restores_visual_items_dropped_by_review(tmp_path):
    provider = FakePhotoProvider(
        {
            "items": [
                {
                    "name": "炸鸡块",
                    "estimated_grams": 120,
                    "quantity": 4,
                    "unit": "块",
                    "cooking_method": "炸",
                    "is_mixed_dish": False,
                    "visible_confidence": 0.92,
                },
                {
                    "name": "炸薯条",
                    "estimated_grams": 90,
                    "quantity": 1,
                    "unit": "份",
                    "cooking_method": "炸",
                    "is_mixed_dish": False,
                    "visible_confidence": 0.88,
                },
            ],
            "description": "油炸拼盘",
        },
        {
            "foods": [
                {
                    "name": "炸鸡块",
                    "calories": 300,
                    "protein": 18,
                    "carbs": 12,
                    "fat": 20,
                    "fiber": 0,
                    "sugar": 0,
                    "added_sugar": 0,
                    "sodium": 600,
                    "serving_size": "120克",
                    "processing_level": "processed",
                }
            ],
            "description": "复核漏掉薯条",
        },
    )

    service = DescribeMealService(provider=provider, food_db=make_food_db(tmp_path))
    foods, _, _ = await service._analyze_image(tiny_base64())

    assert [food.name for food in foods] == ["炸鸡块", "炸薯条"]
    assert foods[1].serving_size == "90克"
    assert foods[1].calories > 0


@pytest.mark.asyncio
async def test_photo_pipeline_surfaces_provider_failure(tmp_path):
    service = DescribeMealService(provider=FailingPhotoProvider(), food_db=make_food_db(tmp_path))

    foods, description, metadata = await service._analyze_image(tiny_base64())

    assert foods == []
    assert "MiMo 图片模型连接失败" in description
    assert metadata["strategy"] == "image_provider_failed"


@pytest.mark.asyncio
async def test_photo_pipeline_surfaces_invalid_mimo_key(tmp_path):
    service = DescribeMealService(provider=InvalidKeyPhotoProvider(), food_db=make_food_db(tmp_path))

    foods, description, metadata = await service._analyze_image(tiny_base64())

    assert foods == []
    assert "MiMo API Key 无效" in description
    assert metadata["strategy"] == "image_provider_failed"


def test_find_nutrition_candidates_returns_clean_quality_candidate(tmp_path):
    food_db = make_food_db(tmp_path)
    create_foods_clean(food_db)

    candidates = food_db.find_nutrition_candidates("米饭", limit=5)

    assert candidates
    assert candidates[0]["name"] == "米饭（蒸，代表值）"
    assert candidates[0]["quality_status"] == "ok"


def test_find_nutrition_candidates_filters_unreasonable_fresh_produce(tmp_path):
    food_db = make_food_db(tmp_path)
    create_foods_clean(food_db)

    candidates = food_db.find_nutrition_candidates("西洋芹菜片", limit=5)

    assert candidates
    assert candidates[0]["name"] == "西洋芹菜"
    assert candidates[0]["per_100g_nutrition"]["calories"] == pytest.approx(11.2, abs=0.1)
    assert all(candidate["name"] != "西洋芹菜片" for candidate in candidates)
