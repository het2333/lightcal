"""USDA FoodData Central API client.

Fetches verified nutrition data for foods from the USDA database.
Free API key registration: https://fdc.nal.usda.gov/api-key-signup.html

Data types:
  - Foundation: USDA lab-analyzed (most accurate)
  - SR Legacy: historical standard reference
  - Branded: manufacturer label data (40K+ products)
"""

import asyncio
from typing import Optional

import httpx

BASE_URL = "https://api.nal.usda.gov/fdc/v1"

# USDA nutrient ID → our field mapping
NUTRIENT_MAP = {
    # (nutrient_id, nutrient_name_keyword) → (our_field, unit)
    1008: ("calories", "kcal"),    # Energy
    1003: ("protein", "g"),         # Protein
    1005: ("carbs", "g"),           # Carbohydrate, by difference
    1004: ("fat", "g"),             # Total lipid (fat)
    1079: ("fiber", "g"),           # Fiber, total dietary
    2000: ("sugar", "g"),           # Sugars, total
    1235: ("added_sugar", "g"),     # Sugars, added
    1093: ("sodium", "mg"),         # Sodium, Na
    1258: ("sat_fat", "g"),         # Fatty acids, total saturated
    1257: ("trans_fat", "g"),       # Fatty acids, total trans
    1253: ("cholesterol", "mg"),    # Cholesterol
    1106: ("vitamin_a", "mcg"),     # Vitamin A, RAE
    1162: ("vitamin_c", "mg"),      # Vitamin C
    1087: ("calcium", "mg"),        # Calcium
    1089: ("iron", "mg"),           # Iron
    1092: ("potassium", "mg"),      # Potassium
}


class USDAClient:
    """Client for USDA FoodData Central API."""

    def __init__(self, api_key: str = "DEMO_KEY"):
        self.api_key = api_key
        self.base = BASE_URL

    async def search(self, query: str, data_type: str = "Foundation,SR%20Legacy", limit: int = 5) -> list[dict]:
        """Search for foods by name. Returns list of food summaries."""
        url = (
            f"{self.base}/foods/search"
            f"?api_key={self.api_key}"
            f"&query={query}"
            f"&dataType={data_type}"
            f"&pageSize={limit}"
        )
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.get(url)
            data = resp.json()
            return data.get("foods", [])

    async def get_food(self, fdc_id: int) -> Optional[dict]:
        """Get full nutrition details for a specific food by FDC ID."""
        url = f"{self.base}/food/{fdc_id}?api_key={self.api_key}"
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.get(url)
            if resp.status_code == 200:
                return resp.json()
            return None

    async def search_branded(self, query: str, limit: int = 5) -> list[dict]:
        """Search branded (packaged) foods."""
        return await self.search(query, data_type="Branded", limit=limit)

    async def get_nutrition(self, fdc_id: int) -> dict:
        """Fetch food and extract nutrition in our standard format."""
        food = await self.get_food(fdc_id)
        if not food:
            return {}

        result = {
            "name": food.get("description", ""),
            "serving_size": self._extract_serving(food),
            "processing_level": self._classify_processing(food),
            "calories": 0, "protein": 0, "carbs": 0, "fat": 0,
            "fiber": 0, "sugar": 0, "sodium": 0, "added_sugar": 0,
            "sat_fat": 0, "trans_fat": 0, "cholesterol": 0,
            "vitamin_a": 0, "vitamin_c": 0, "calcium": 0,
            "iron": 0, "potassium": 0,
            "source": "USDA",
            "source_detail": food.get("dataType", ""),
        }

        for nutrient in food.get("foodNutrients", []):
            nid = nutrient.get("nutrient", {}).get("id")
            if nid in NUTRIENT_MAP:
                field, _ = NUTRIENT_MAP[nid]
                result[field] = nutrient.get("amount", 0)

        return result

    @staticmethod
    def _extract_serving(food: dict) -> str:
        """Extract serving size description."""
        portions = food.get("foodPortions", [])
        if portions:
            p = portions[0]
            amount = p.get("amount", 100)
            unit = p.get("modifier", "g")
            return f"{amount}{unit}"
        ss = food.get("servingSize", 100)
        unit = food.get("servingSizeUnit", "g")
        return f"{ss}{unit}"

    @staticmethod
    def _classify_processing(food: dict) -> str:
        """Guess processing level from USDA data type."""
        dt = food.get("dataType", "")
        if dt in ("Foundation", "SR Legacy"):
            return "whole"
        if dt == "Branded":
            return "processed"
        return "whole"

    async def lookup_and_map(self, food_name: str) -> Optional[dict]:
        """Search for a food by name and return nutrition for the best match."""
        results = await self.search(food_name, limit=1)
        if not results:
            return None
        fdc_id = results[0].get("fdcId")
        if not fdc_id:
            return None
        return await self.get_nutrition(fdc_id)


# ── Batch importer ────────────────────────────────────────────────

async def import_usda_foods(api_key: str, db_path, food_names: list[str]) -> int:
    """Import USDA nutrition data for a list of food names into the database."""
    import sqlite3

    client = USDAClient(api_key)
    conn = sqlite3.connect(str(db_path))
    imported = 0

    for name in food_names:
        try:
            nutrition = await client.lookup_and_map(name)
            if not nutrition or nutrition.get("calories", 0) <= 0:
                continue

            import uuid
            food_id = uuid.uuid4().hex[:12]
            conn.execute(
                """INSERT OR REPLACE INTO foods
                   (id, name, calories, protein, carbs, fat, fiber, sugar,
                    added_sugar, sodium, sat_fat, trans_fat, cholesterol,
                    vitamin_a, vitamin_c, calcium, iron, potassium,
                    serving_size, processing_level, source)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    food_id,
                    nutrition["name"],
                    nutrition["calories"],
                    nutrition["protein"],
                    nutrition["carbs"],
                    nutrition["fat"],
                    nutrition["fiber"],
                    nutrition["sugar"],
                    nutrition.get("added_sugar", 0),
                    nutrition["sodium"],
                    nutrition.get("sat_fat", 0),
                    nutrition.get("trans_fat", 0),
                    nutrition.get("cholesterol", 0),
                    nutrition.get("vitamin_a", 0),
                    nutrition.get("vitamin_c", 0),
                    nutrition.get("calcium", 0),
                    nutrition.get("iron", 0),
                    nutrition.get("potassium", 0),
                    nutrition["serving_size"],
                    nutrition["processing_level"],
                    "USDA",
                ),
            )
            imported += 1
            print(f"  ✓ {nutrition['name']}: {nutrition['calories']}kcal P:{nutrition['protein']}g")
            # Rate limit: ~1/sec for DEMO_KEY
            await asyncio.sleep(1.2)
        except Exception as e:
            print(f"  ✗ {name}: {e}")

    conn.commit()
    conn.close()
    print(f"\nImported {imported} USDA-verified foods")
    return imported


# ── Chinese food composition supplement ────────────────────────────

# 中国食物成分表 (精选常用项, 权威来源)
# Source: 中国疾控中心营养与健康所, 《中国食物成分表》标准版第6版
CHINESE_FOOD_DB: list[dict] = [
    # 主食 (grains)
    {"name": "米饭(蒸)", "calories": 116, "protein": 2.6, "carbs": 26, "fat": 0.3, "fiber": 0.3, "sugar": 0, "added_sugar": 0, "sodium": 2.5, "serving_size": "100g", "processing_level": "minimally_processed"},
    {"name": "馒头(标准粉)", "calories": 233, "protein": 7.8, "carbs": 44, "fat": 1.0, "fiber": 1.5, "sugar": 1.5, "added_sugar": 0, "sodium": 6, "serving_size": "100g", "processing_level": "processed"},
    {"name": "面条(煮)", "calories": 110, "protein": 4.0, "carbs": 22, "fat": 0.4, "fiber": 0.5, "sugar": 0.3, "added_sugar": 0, "sodium": 2, "serving_size": "100g", "processing_level": "minimally_processed"},
    {"name": "小米粥", "calories": 46, "protein": 1.4, "carbs": 8.4, "fat": 0.7, "fiber": 0.5, "sugar": 0, "added_sugar": 0, "sodium": 2, "serving_size": "100g", "processing_level": "minimally_processed"},
    {"name": "油条", "calories": 386, "protein": 6.9, "carbs": 51, "fat": 18, "fiber": 1.4, "sugar": 2, "added_sugar": 1, "sodium": 585, "serving_size": "100g", "processing_level": "ultra_processed"},

    # 肉类 (meats)
    {"name": "猪肉(瘦)", "calories": 143, "protein": 20, "carbs": 1.5, "fat": 6.2, "fiber": 0, "sugar": 0, "added_sugar": 0, "sodium": 57, "serving_size": "100g", "processing_level": "whole"},
    {"name": "猪肉(肥瘦)", "calories": 395, "protein": 13, "carbs": 2.4, "fat": 37, "fiber": 0, "sugar": 0, "added_sugar": 0, "sodium": 59, "serving_size": "100g", "processing_level": "whole"},
    {"name": "猪排骨", "calories": 264, "protein": 18, "carbs": 0, "fat": 21, "fiber": 0, "sugar": 0, "added_sugar": 0, "sodium": 55, "serving_size": "100g", "processing_level": "whole"},
    {"name": "牛肉(瘦)", "calories": 106, "protein": 20, "carbs": 1.2, "fat": 2.3, "fiber": 0, "sugar": 0, "added_sugar": 0, "sodium": 53, "serving_size": "100g", "processing_level": "whole"},
    {"name": "牛肉(肥瘦)", "calories": 190, "protein": 18, "carbs": 2.0, "fat": 13, "fiber": 0, "sugar": 0, "added_sugar": 0, "sodium": 84, "serving_size": "100g", "processing_level": "whole"},
    {"name": "羊肉(瘦)", "calories": 118, "protein": 20, "carbs": 0.2, "fat": 3.9, "fiber": 0, "sugar": 0, "added_sugar": 0, "sodium": 69, "serving_size": "100g", "processing_level": "whole"},
    {"name": "鸡胸肉", "calories": 133, "protein": 19, "carbs": 2.5, "fat": 5.0, "fiber": 0, "sugar": 0, "added_sugar": 0, "sodium": 34, "serving_size": "100g", "processing_level": "whole"},
    {"name": "鸡腿", "calories": 181, "protein": 16, "carbs": 0, "fat": 13, "fiber": 0, "sugar": 0, "added_sugar": 0, "sodium": 60, "serving_size": "100g", "processing_level": "whole"},
    {"name": "鸭肉", "calories": 240, "protein": 15, "carbs": 0.2, "fat": 20, "fiber": 0, "sugar": 0, "added_sugar": 0, "sodium": 65, "serving_size": "100g", "processing_level": "whole"},

    # 水产 (seafood)
    {"name": "草鱼", "calories": 113, "protein": 17, "carbs": 0, "fat": 5.2, "fiber": 0, "sugar": 0, "added_sugar": 0, "sodium": 46, "serving_size": "100g", "processing_level": "whole"},
    {"name": "鲤鱼", "calories": 109, "protein": 18, "carbs": 0.5, "fat": 4.1, "fiber": 0, "sugar": 0, "added_sugar": 0, "sodium": 50, "serving_size": "100g", "processing_level": "whole"},
    {"name": "带鱼", "calories": 127, "protein": 18, "carbs": 0, "fat": 6.2, "fiber": 0, "sugar": 0, "added_sugar": 0, "sodium": 150, "serving_size": "100g", "processing_level": "whole"},
    {"name": "虾仁", "calories": 48, "protein": 11, "carbs": 0.5, "fat": 0.2, "fiber": 0, "sugar": 0, "added_sugar": 0, "sodium": 160, "serving_size": "100g", "processing_level": "whole"},
    {"name": "鲈鱼", "calories": 105, "protein": 19, "carbs": 0, "fat": 3.4, "fiber": 0, "sugar": 0, "added_sugar": 0, "sodium": 65, "serving_size": "100g", "processing_level": "whole"},
    {"name": "三文鱼", "calories": 139, "protein": 17, "carbs": 0, "fat": 7.8, "fiber": 0, "sugar": 0, "added_sugar": 0, "sodium": 63, "serving_size": "100g", "processing_level": "whole"},

    # 蔬菜 (vegetables)
    {"name": "大白菜", "calories": 17, "protein": 1.5, "carbs": 3.2, "fat": 0.2, "fiber": 0.8, "sugar": 1.6, "added_sugar": 0, "sodium": 57, "serving_size": "100g", "processing_level": "whole"},
    {"name": "菠菜", "calories": 24, "protein": 2.6, "carbs": 4.5, "fat": 0.3, "fiber": 1.7, "sugar": 0.4, "added_sugar": 0, "sodium": 85, "serving_size": "100g", "processing_level": "whole"},
    {"name": "西兰花", "calories": 33, "protein": 4.1, "carbs": 4.3, "fat": 0.6, "fiber": 1.6, "sugar": 1.4, "added_sugar": 0, "sodium": 27, "serving_size": "100g", "processing_level": "whole"},
    {"name": "番茄", "calories": 19, "protein": 0.9, "carbs": 4.0, "fat": 0.2, "fiber": 0.5, "sugar": 2.4, "added_sugar": 0, "sodium": 5, "serving_size": "100g", "processing_level": "whole"},
    {"name": "黄瓜", "calories": 15, "protein": 0.8, "carbs": 2.9, "fat": 0.2, "fiber": 0.5, "sugar": 1.7, "added_sugar": 0, "sodium": 4.9, "serving_size": "100g", "processing_level": "whole"},
    {"name": "胡萝卜", "calories": 37, "protein": 1.0, "carbs": 8.8, "fat": 0.2, "fiber": 1.3, "sugar": 4.5, "added_sugar": 0, "sodium": 71, "serving_size": "100g", "processing_level": "whole"},
    {"name": "土豆", "calories": 76, "protein": 2.0, "carbs": 17, "fat": 0.2, "fiber": 0.7, "sugar": 0.8, "added_sugar": 0, "sodium": 2.7, "serving_size": "100g", "processing_level": "whole"},
    {"name": "茄子", "calories": 21, "protein": 1.1, "carbs": 4.9, "fat": 0.2, "fiber": 1.3, "sugar": 2.3, "added_sugar": 0, "sodium": 5.4, "serving_size": "100g", "processing_level": "whole"},
    {"name": "青椒", "calories": 22, "protein": 1.0, "carbs": 5.4, "fat": 0.2, "fiber": 1.4, "sugar": 2.3, "added_sugar": 0, "sodium": 3.3, "serving_size": "100g", "processing_level": "whole"},
    {"name": "芹菜", "calories": 14, "protein": 0.8, "carbs": 3.9, "fat": 0.1, "fiber": 1.4, "sugar": 1.3, "added_sugar": 0, "sodium": 73, "serving_size": "100g", "processing_level": "whole"},
    {"name": "冬瓜", "calories": 11, "protein": 0.4, "carbs": 2.6, "fat": 0.2, "fiber": 0.7, "sugar": 1.4, "added_sugar": 0, "sodium": 1.8, "serving_size": "100g", "processing_level": "whole"},
    {"name": "洋葱", "calories": 39, "protein": 1.1, "carbs": 9.0, "fat": 0.2, "fiber": 0.9, "sugar": 4.2, "added_sugar": 0, "sodium": 4.4, "serving_size": "100g", "processing_level": "whole"},

    # 菌菇豆 (mushrooms, beans)
    {"name": "蘑菇(鲜)", "calories": 20, "protein": 2.7, "carbs": 4.1, "fat": 0.1, "fiber": 2.1, "sugar": 1.7, "added_sugar": 0, "sodium": 8, "serving_size": "100g", "processing_level": "whole"},
    {"name": "木耳(干)", "calories": 205, "protein": 12, "carbs": 66, "fat": 1.5, "fiber": 30, "sugar": 3.5, "added_sugar": 0, "sodium": 42, "serving_size": "100g", "processing_level": "minimally_processed"},
    {"name": "豆腐", "calories": 81, "protein": 8.1, "carbs": 4.2, "fat": 3.7, "fiber": 0.4, "sugar": 0.8, "added_sugar": 0, "sodium": 7.2, "serving_size": "100g", "processing_level": "processed"},
    {"name": "豆浆", "calories": 14, "protein": 1.8, "carbs": 1.1, "fat": 0.7, "fiber": 0, "sugar": 0.4, "added_sugar": 0, "sodium": 3, "serving_size": "100ml", "processing_level": "minimally_processed"},
    {"name": "腐竹", "calories": 459, "protein": 45, "carbs": 22, "fat": 22, "fiber": 1.0, "sugar": 5, "added_sugar": 0, "sodium": 26, "serving_size": "100g", "processing_level": "processed"},

    # 水果 (fruits)
    {"name": "苹果", "calories": 52, "protein": 0.2, "carbs": 13, "fat": 0.2, "fiber": 1.2, "sugar": 10, "added_sugar": 0, "sodium": 1.6, "serving_size": "100g", "processing_level": "whole"},
    {"name": "香蕉", "calories": 91, "protein": 1.4, "carbs": 22, "fat": 0.2, "fiber": 1.2, "sugar": 12, "added_sugar": 0, "sodium": 0.8, "serving_size": "100g", "processing_level": "whole"},
    {"name": "橙子", "calories": 47, "protein": 0.8, "carbs": 11, "fat": 0.2, "fiber": 0.6, "sugar": 9, "added_sugar": 0, "sodium": 1.2, "serving_size": "100g", "processing_level": "whole"},
    {"name": "葡萄", "calories": 43, "protein": 0.5, "carbs": 10, "fat": 0.2, "fiber": 0.4, "sugar": 8, "added_sugar": 0, "sodium": 1.3, "serving_size": "100g", "processing_level": "whole"},
    {"name": "西瓜", "calories": 25, "protein": 0.6, "carbs": 5.8, "fat": 0.1, "fiber": 0.3, "sugar": 4.2, "added_sugar": 0, "sodium": 3.2, "serving_size": "100g", "processing_level": "whole"},
    {"name": "芒果", "calories": 32, "protein": 0.6, "carbs": 8.3, "fat": 0.2, "fiber": 1.3, "sugar": 7.2, "added_sugar": 0, "sodium": 2.8, "serving_size": "100g", "processing_level": "whole"},
    {"name": "草莓", "calories": 30, "protein": 1.0, "carbs": 7.1, "fat": 0.2, "fiber": 1.1, "sugar": 4.1, "added_sugar": 0, "sodium": 4.2, "serving_size": "100g", "processing_level": "whole"},
    {"name": "猕猴桃", "calories": 56, "protein": 0.8, "carbs": 14, "fat": 0.6, "fiber": 2.6, "sugar": 9, "added_sugar": 0, "sodium": 10, "serving_size": "100g", "processing_level": "whole"},
    {"name": "火龙果", "calories": 55, "protein": 1.1, "carbs": 13, "fat": 0.4, "fiber": 1.6, "sugar": 9.0, "added_sugar": 0, "sodium": 2.3, "serving_size": "100g", "processing_level": "whole"},

    # 蛋奶 (eggs, dairy)
    {"name": "鸡蛋", "calories": 144, "protein": 13, "carbs": 2.8, "fat": 8.8, "fiber": 0, "sugar": 1.5, "added_sugar": 0, "sodium": 132, "serving_size": "100g (约2个)", "processing_level": "whole"},
    {"name": "鸭蛋", "calories": 180, "protein": 13, "carbs": 3.1, "fat": 13, "fiber": 0, "sugar": 1.2, "added_sugar": 0, "sodium": 106, "serving_size": "100g", "processing_level": "whole"},
    {"name": "牛奶(纯)", "calories": 54, "protein": 3.0, "carbs": 3.4, "fat": 3.2, "fiber": 0, "sugar": 3.4, "added_sugar": 0, "sodium": 37, "serving_size": "100ml", "processing_level": "minimally_processed"},
    {"name": "酸奶(原味)", "calories": 72, "protein": 2.5, "carbs": 9.3, "fat": 2.7, "fiber": 0, "sugar": 8.5, "added_sugar": 5, "sodium": 39, "serving_size": "100g", "processing_level": "processed"},

    # 常见菜肴 (common dishes) - 平均值
    {"name": "番茄炒蛋", "calories": 85, "protein": 5.0, "carbs": 4.0, "fat": 5.5, "fiber": 0.6, "sugar": 2.2, "added_sugar": 0, "sodium": 200, "serving_size": "100g", "processing_level": "whole"},
    {"name": "青椒肉丝", "calories": 90, "protein": 9.0, "carbs": 3.5, "fat": 5.0, "fiber": 0.8, "sugar": 1.5, "added_sugar": 0, "sodium": 350, "serving_size": "100g", "processing_level": "processed"},
    {"name": "鱼香肉丝", "calories": 120, "protein": 8.0, "carbs": 8.0, "fat": 7.0, "fiber": 1.0, "sugar": 4.0, "added_sugar": 2.5, "sodium": 500, "serving_size": "100g", "processing_level": "processed"},
    {"name": "宫保鸡丁", "calories": 145, "protein": 14, "carbs": 6.0, "fat": 8.0, "fiber": 1.2, "sugar": 3.5, "added_sugar": 2.0, "sodium": 520, "serving_size": "100g", "processing_level": "processed"},
    {"name": "麻婆豆腐", "calories": 85, "protein": 6.5, "carbs": 3.5, "fat": 5.5, "fiber": 0.8, "sugar": 1.0, "added_sugar": 0, "sodium": 550, "serving_size": "100g", "processing_level": "processed"},
    {"name": "红烧肉", "calories": 285, "protein": 11, "carbs": 6.0, "fat": 24, "fiber": 0.3, "sugar": 4.5, "added_sugar": 3.5, "sodium": 400, "serving_size": "100g", "processing_level": "processed"},
    {"name": "回锅肉", "calories": 220, "protein": 12, "carbs": 2.5, "fat": 18, "fiber": 0.5, "sugar": 1.5, "added_sugar": 0.5, "sodium": 480, "serving_size": "100g", "processing_level": "processed"},
    {"name": "水煮鱼", "calories": 110, "protein": 14, "carbs": 1.5, "fat": 5.5, "fiber": 0.5, "sugar": 0.3, "added_sugar": 0, "sodium": 620, "serving_size": "100g", "processing_level": "processed"},
    {"name": "蛋炒饭", "calories": 160, "protein": 5.5, "carbs": 24, "fat": 5.0, "fiber": 0.5, "sugar": 0.5, "added_sugar": 0, "sodium": 300, "serving_size": "100g", "processing_level": "processed"},
    {"name": "扬州炒饭", "calories": 175, "protein": 6.5, "carbs": 23, "fat": 6.5, "fiber": 1.0, "sugar": 1.0, "added_sugar": 0, "sodium": 380, "serving_size": "100g", "processing_level": "processed"},
    {"name": "蛋花汤", "calories": 18, "protein": 1.5, "carbs": 1.0, "fat": 1.0, "fiber": 0.1, "sugar": 0.3, "added_sugar": 0, "sodium": 250, "serving_size": "100ml", "processing_level": "whole"},
    {"name": "酸辣汤", "calories": 30, "protein": 2.0, "carbs": 3.5, "fat": 1.0, "fiber": 0.5, "sugar": 0.5, "added_sugar": 0, "sodium": 550, "serving_size": "100ml", "processing_level": "processed"},

    # 小吃 (snacks)
    {"name": "饺子(猪肉)", "calories": 220, "protein": 8.5, "carbs": 25, "fat": 9.5, "fiber": 1.0, "sugar": 2.5, "added_sugar": 0, "sodium": 350, "serving_size": "100g (约5个)", "processing_level": "processed"},
    {"name": "馄饨", "calories": 180, "protein": 7.0, "carbs": 22, "fat": 7.5, "fiber": 0.8, "sugar": 2.0, "added_sugar": 0, "sodium": 380, "serving_size": "100g (约8个)", "processing_level": "processed"},
    {"name": "小笼包", "calories": 210, "protein": 9.0, "carbs": 25, "fat": 8.5, "fiber": 0.8, "sugar": 2.5, "added_sugar": 0, "sodium": 320, "serving_size": "100g (约4个)", "processing_level": "processed"},
    {"name": "春卷(炸)", "calories": 310, "protein": 6.0, "carbs": 35, "fat": 16, "fiber": 2.0, "sugar": 3.0, "added_sugar": 0, "sodium": 400, "serving_size": "100g", "processing_level": "ultra_processed"},

    # 饮料 (beverages)
    {"name": "可口可乐", "calories": 43, "protein": 0, "carbs": 10.6, "fat": 0, "fiber": 0, "sugar": 10.6, "added_sugar": 10.6, "sodium": 4, "serving_size": "100ml", "processing_level": "ultra_processed"},
    {"name": "雪碧", "calories": 41, "protein": 0, "carbs": 10.2, "fat": 0, "fiber": 0, "sugar": 10.2, "added_sugar": 10.2, "sodium": 6, "serving_size": "100ml", "processing_level": "ultra_processed"},
    {"name": "橙汁(鲜榨)", "calories": 45, "protein": 0.7, "carbs": 10.4, "fat": 0.2, "fiber": 0.2, "sugar": 8.4, "added_sugar": 0, "sodium": 1, "serving_size": "100ml", "processing_level": "minimally_processed"},
    {"name": "啤酒", "calories": 32, "protein": 0.4, "carbs": 2.5, "fat": 0, "fiber": 0, "sugar": 0, "added_sugar": 0, "sodium": 4, "serving_size": "100ml", "processing_level": "processed"},
    {"name": "红茶", "calories": 1, "protein": 0, "carbs": 0.2, "fat": 0, "fiber": 0, "sugar": 0, "added_sugar": 0, "sodium": 2, "serving_size": "100ml", "processing_level": "minimally_processed"},
    {"name": "绿茶", "calories": 1, "protein": 0, "carbs": 0.2, "fat": 0, "fiber": 0, "sugar": 0, "added_sugar": 0, "sodium": 2, "serving_size": "100ml", "processing_level": "minimally_processed"},

    # 调味品 (condiments)
    {"name": "植物油", "calories": 899, "protein": 0, "carbs": 0, "fat": 100, "fiber": 0, "sugar": 0, "added_sugar": 0, "sodium": 0, "serving_size": "100g", "processing_level": "processed"},
    {"name": "酱油", "calories": 63, "protein": 5.6, "carbs": 10, "fat": 0.1, "fiber": 0.2, "sugar": 5.5, "added_sugar": 2.0, "sodium": 5757, "serving_size": "100ml", "processing_level": "processed"},
    {"name": "醋", "calories": 31, "protein": 2.1, "carbs": 4.9, "fat": 0.3, "fiber": 0, "sugar": 2.0, "added_sugar": 0, "sodium": 262, "serving_size": "100ml", "processing_level": "processed"},
    {"name": "白糖", "calories": 396, "protein": 0, "carbs": 99, "fat": 0, "fiber": 0, "sugar": 99, "added_sugar": 99, "sodium": 1, "serving_size": "100g", "processing_level": "processed"},
    {"name": "食盐", "calories": 0, "protein": 0, "carbs": 0, "fat": 0, "fiber": 0, "sugar": 0, "added_sugar": 0, "sodium": 39311, "serving_size": "100g", "processing_level": "processed"},
    {"name": "味精", "calories": 268, "protein": 40, "carbs": 27, "fat": 0.2, "fiber": 0, "sugar": 0, "added_sugar": 0, "sodium": 21000, "serving_size": "100g", "processing_level": "processed"},
    {"name": "辣椒油", "calories": 900, "protein": 0, "carbs": 0, "fat": 100, "fiber": 0, "sugar": 0, "added_sugar": 0, "sodium": 0, "serving_size": "100g", "processing_level": "processed"},
    {"name": "豆瓣酱", "calories": 178, "protein": 11, "carbs": 8.0, "fat": 5.5, "fiber": 2.5, "sugar": 2.0, "added_sugar": 1.0, "sodium": 6100, "serving_size": "100g", "processing_level": "processed"},
    {"name": "蚝油", "calories": 90, "protein": 3.5, "carbs": 17, "fat": 0.6, "fiber": 0, "sugar": 12, "added_sugar": 10, "sodium": 4500, "serving_size": "100g", "processing_level": "processed"},

    # 坚果 (nuts)
    {"name": "花生(炒)", "calories": 589, "protein": 22, "carbs": 24, "fat": 48, "fiber": 6.3, "sugar": 4.5, "added_sugar": 0, "sodium": 300, "serving_size": "100g", "processing_level": "processed"},
    {"name": "核桃", "calories": 627, "protein": 15, "carbs": 19, "fat": 58, "fiber": 9.5, "sugar": 2.6, "added_sugar": 0, "sodium": 6.4, "serving_size": "100g", "processing_level": "whole"},
    {"name": "杏仁", "calories": 562, "protein": 21, "carbs": 22, "fat": 45, "fiber": 8.0, "sugar": 4.5, "added_sugar": 0, "sodium": 3.5, "serving_size": "100g", "processing_level": "whole"},
    {"name": "腰果", "calories": 552, "protein": 18, "carbs": 30, "fat": 44, "fiber": 3.3, "sugar": 5.9, "added_sugar": 0, "sodium": 12, "serving_size": "100g", "processing_level": "whole"},
    {"name": "瓜子(炒)", "calories": 574, "protein": 20, "carbs": 24, "fat": 46, "fiber": 4.7, "sugar": 2.9, "added_sugar": 0, "sodium": 250, "serving_size": "100g", "processing_level": "processed"},
]


def import_chinese_food_db(db_path) -> int:
    """Import Chinese food composition data into the database."""
    import sqlite3, uuid

    conn = sqlite3.connect(str(db_path))
    imported = 0

    for item in CHINESE_FOOD_DB:
        food_id = uuid.uuid4().hex[:12]
        try:
            conn.execute(
                """INSERT OR REPLACE INTO foods
                   (id, name, calories, protein, carbs, fat, fiber, sugar,
                    added_sugar, sodium, serving_size, processing_level, source)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    food_id, item["name"], item["calories"], item["protein"],
                    item["carbs"], item["fat"], item["fiber"], item["sugar"],
                    item.get("added_sugar", 0), item["sodium"],
                    item["serving_size"], item["processing_level"], "中国食物成分表",
                ),
            )
            imported += 1
        except Exception:
            pass

    conn.commit()
    conn.close()
    print(f"Imported {imported} Chinese food composition entries")
    return imported
