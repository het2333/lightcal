"""Meal recommendation service backed by the real food database.

The rule engine always produces usable recommendations. LLM output, when
available, may only rewrite titles/reasons and never nutrition numbers.
"""

from __future__ import annotations

import json
import re
import time
from datetime import date
from typing import Any
from urllib.parse import quote
from uuid import uuid4

from models.food import Food
from models.tracking import DailySummary
from services.food_database import FoodDatabase
from services.tracking_service import TrackingService


class RecommendationService:
    """Build and persist nutrition-aware meal recommendations."""

    PROTEIN_KEYWORDS = [
        "鸡", "牛", "猪", "鱼", "虾", "蛋", "豆腐", "酸奶", "牛奶",
        "chicken", "beef", "pork", "fish", "salmon", "egg", "tofu", "yogurt",
    ]
    CARB_KEYWORDS = [
        "米", "饭", "面", "粥", "馒头", "燕麦", "面包", "土豆", "红薯", "玉米",
        "rice", "noodle", "bread", "oat", "potato",
    ]
    VEGETABLE_KEYWORDS = [
        "菜", "西兰花", "菠菜", "生菜", "番茄", "黄瓜", "蘑菇", "豆角", "胡萝卜",
        "vegetable", "broccoli", "spinach", "salad", "tomato", "mushroom",
    ]
    FRUIT_KEYWORDS = ["苹果", "香蕉", "橙", "草莓", "蓝莓", "梨", "fruit", "apple", "banana", "orange"]
    SNACK_KEYWORDS = ["坚果", "酸奶", "鸡蛋", "苹果", "香蕉", "杏仁", "核桃", "nuts", "yogurt", "egg"]
    MEAT_KEYWORDS = ["鸡", "牛", "猪", "鱼", "虾", "羊", "肉", "chicken", "beef", "pork", "fish", "shrimp"]

    MEAL_RATIOS = {
        "breakfast": 0.25,
        "lunch": 0.35,
        "dinner": 0.35,
        "snack": 0.12,
    }

    MEAL_LABELS = {
        "breakfast": "早餐",
        "lunch": "午餐",
        "dinner": "晚餐",
        "snack": "加餐",
    }

    DELIVERY_PLATFORM_LABELS = {
        "any": "都可以",
        "meituan": "美团",
        "eleme": "饿了么",
    }

    EN_NAME_ALIASES = [
        ("chicken breast", "鸡胸肉"),
        ("fried chicken", "炸鸡"),
        ("grilled chicken", "烤鸡"),
        ("chicken", "鸡肉"),
        ("beef", "牛肉"),
        ("pork", "猪肉"),
        ("salmon", "三文鱼"),
        ("shrimp", "虾仁"),
        ("fish", "鱼肉"),
        ("tofu", "豆腐"),
        ("egg", "鸡蛋"),
        ("yogurt", "酸奶"),
        ("milk", "牛奶"),
        ("white rice", "白米饭"),
        ("brown rice", "糙米饭"),
        ("rice", "米饭"),
        ("noodle", "面条"),
        ("oat", "燕麦"),
        ("bread", "面包"),
        ("potato", "土豆"),
        ("sweet potato", "红薯"),
        ("corn", "玉米"),
        ("broccoli", "西兰花"),
        ("spinach", "菠菜"),
        ("salad", "沙拉"),
        ("lettuce", "生菜"),
        ("tomato", "番茄"),
        ("mushroom", "蘑菇"),
        ("carrot", "胡萝卜"),
        ("apple", "苹果"),
        ("banana", "香蕉"),
        ("orange", "橙子"),
        ("fruit", "水果"),
        ("nuts", "坚果"),
        ("almond", "杏仁"),
    ]

    def __init__(
        self,
        food_db: FoodDatabase,
        tracking: TrackingService,
        llm_provider: Any | None = None,
        decision_service: Any | None = None,
    ):
        self.food_db = food_db
        self.tracking = tracking
        self.llm_provider = llm_provider
        self.decision_service = decision_service
        self._candidate_cache: list[Food] = []
        self._candidate_cache_at = 0.0
        self._candidate_cache_ttl_seconds = 600.0

    async def today(
        self,
        summary: DailySummary,
        meal_type: str | None = None,
        limit: int = 3,
        prep_time_minutes: int | None = None,
        use_ai: bool = True,
    ) -> dict:
        preferences = self.tracking.get_user_preferences()
        meal_type = self._normalize_meal_type(meal_type)
        if prep_time_minutes:
            preferences["prep_time_minutes"] = prep_time_minutes

        candidates = self._load_food_candidates()
        filtered = self._filter_candidates(candidates, preferences)
        if not filtered:
            filtered = candidates

        remaining = self._remaining(summary)
        target = self._target_calories(summary, remaining, meal_type)
        recommendations = self._build_recommendations(
            filtered, summary, remaining, target, meal_type, preferences, max(1, min(limit, 8))
        )

        source = "rules"
        if use_ai and self.llm_provider and recommendations:
            try:
                recommendations = await self._enhance_with_ai(recommendations, summary, preferences, meal_type)
                source = "ai_enhanced"
            except Exception:
                source = "rules"

        day = summary.date or date.today().isoformat()
        persisted_recommendations = []
        for rec in recommendations:
            rec["source"] = source
            persisted_recommendations.append(self.tracking.save_recommendation_event(
                rec["id"], day, rec["meal_type"], source, rec
            ))
        recommendations = persisted_recommendations

        return {
            "date": day,
            "summary": summary.model_dump(),
            "remaining": remaining,
            "target_calories": target,
            "preferences": preferences,
            "source": source,
            "recommendations": recommendations,
        }

    def scale_recommendation_foods(self, recommendation: dict, portion_multiplier: float) -> list[Food]:
        multiplier = max(0.5, min(2.0, float(portion_multiplier or 1)))
        foods = []
        for item in recommendation.get("foods", []):
            scaled = dict(item)
            for field in [
                "calories", "protein", "carbs", "fat", "fiber", "sugar",
                "sodium", "added_sugar", "sat_fat", "trans_fat", "cholesterol",
                "vitamin_a", "vitamin_c", "calcium", "iron", "potassium",
            ]:
                scaled[field] = round(float(scaled.get(field) or 0) * multiplier, 1)
            scaled["id"] = uuid4().hex[:12]
            scaled["serving_size"] = self._scale_serving_text(str(scaled.get("serving_size") or "1份"), multiplier)
            foods.append(Food(**scaled))
        return foods

    def build_delivery_draft(
        self,
        recommendation: dict,
        portion_multiplier: float = 1,
        provider: str = "auto",
    ) -> dict:
        """Create a delivery order draft without claiming a real third-party order."""
        multiplier = max(0.5, min(2.0, float(portion_multiplier or 1)))
        items = []
        for food in recommendation.get("foods", []):
            scaled = self._scale_food_dict(food, multiplier)
            items.append({
                "name": scaled.get("name", ""),
                "serving_size": scaled.get("serving_size", ""),
                "calories": round(float(scaled.get("calories") or 0)),
                "protein": round(float(scaled.get("protein") or 0), 1),
                "carbs": round(float(scaled.get("carbs") or 0), 1),
                "fat": round(float(scaled.get("fat") or 0), 1),
            })

        nutrition = {
            "calories": round(sum(item["calories"] for item in items)),
            "protein": round(sum(item["protein"] for item in items)),
            "carbs": round(sum(item["carbs"] for item in items)),
            "fat": round(sum(item["fat"] for item in items)),
        }
        meal_type = recommendation.get("meal_type") or "dinner"
        meal_label = self.MEAL_LABELS.get(meal_type, "下一餐")
        restaurant_hint = self._delivery_restaurant_hint(recommendation, items)
        terms = [self._clean_delivery_term(item["name"]) for item in items]
        terms = [term for term in terms if term][:3]
        search_query = " ".join([restaurant_hint, *terms[:2]]).strip()
        if not search_query:
            search_query = self._clean_delivery_term(recommendation.get("title", "")) or meal_label

        notes = ["少油少盐", "酱料另放", "不配含糖饮料"]
        if any(any(key in item["name"].lower() for key in self.CARB_KEYWORDS) for item in items):
            notes.append("主食小份或半份")
        if nutrition["protein"] < 25 and meal_type != "snack":
            notes.append("可加一份鸡蛋、豆腐或鸡胸肉")
        if float(recommendation.get("sodium") or 0) > 700:
            notes.append("不要额外咸菜和高盐汤包")
        order_note = "，".join(dict.fromkeys(notes))

        eta_minutes = min(55, 24 + len(items) * 4 + (6 if meal_type == "dinner" else 0))
        fee_yuan = round(3.5 + min(5, max(0, nutrition["calories"] - 350) / 180), 1)
        provider_labels = {
            "auto": "任意外卖平台",
            "meituan": "美团",
            "eleme": "饿了么",
            "jd": "京东秒送",
        }
        platform_options = [
            {"id": "meituan", "name": "美团", "url": "https://waimai.meituan.com/", "search_query": search_query},
            {"id": "eleme", "name": "饿了么", "url": "https://www.ele.me/", "search_query": search_query},
            {"id": "jd", "name": "京东秒送", "url": "https://daojia.jd.com/", "search_query": search_query},
        ]
        copy_text = (
            f"搜索：{search_query}\n"
            f"点单备注：{order_note}\n"
            f"目标：约 {nutrition['calories']} kcal，蛋白 {nutrition['protein']}g"
        )

        return {
            "provider": provider or "auto",
            "provider_label": provider_labels.get(provider or "auto", provider_labels["auto"]),
            "search_query": search_query,
            "restaurant_hint": restaurant_hint,
            "eta_minutes": eta_minutes,
            "fee_yuan": fee_yuan,
            "order_note": order_note,
            "order_items": items,
            "nutrition": nutrition,
            "portion_multiplier": multiplier,
            "copy_text": copy_text,
            "platform_options": platform_options,
            "guardrails": [
                "优先选能备注少油少盐的商家",
                "饮料换无糖茶或水",
                "实际下单前按个人忌口复核",
            ],
        }

    def delivery_recommendations(
        self,
        summary: DailySummary,
        preferences: dict,
        limit: int = 3,
        fasting_status: dict | None = None,
    ) -> dict:
        """Generate nutrition-grounded delivery recommendations from user choices."""
        remaining = self._remaining(summary)
        day = summary.date or date.today().isoformat()
        tastes = [str(item) for item in preferences.get("tastes", []) if str(item).strip()]
        meal_types = [str(item) for item in preferences.get("meal_types", []) if str(item).strip()]
        restrictions = [str(item) for item in preferences.get("restrictions", []) if str(item).strip()]
        platform = str(preferences.get("platform") or "any")
        budget = str(preferences.get("budget") or "20-35 元")
        delivery_time = str(preferences.get("delivery_time") or "45 分钟内")
        variant = int(preferences.get("variant") or 0)
        target = max(280, min(780, remaining["calories"] if remaining["calories"] > 0 else 420))

        templates = self._delivery_templates()
        candidates = []
        for template in templates:
            if not self._delivery_option_allowed(template, tastes, meal_types, restrictions):
                continue
            option = self._compose_delivery_option(
                template,
                summary,
                remaining,
                target,
                tastes,
                meal_types,
                restrictions,
                platform,
                budget,
                delivery_time,
                fasting_status,
            )
            candidates.append(option)

        if not candidates:
            fallback = [item for item in templates if "高蛋白" in item["tags"]][:6]
            candidates = [
                self._compose_delivery_option(
                    item, summary, remaining, target, tastes, meal_types, restrictions,
                    platform, budget, delivery_time, fasting_status,
                )
                for item in fallback
            ]

        candidates.sort(key=lambda item: item["score"], reverse=True)
        if candidates and variant:
            offset = variant % len(candidates)
            candidates = candidates[offset:] + candidates[:offset]
        source = "delivery_rules"
        persisted_candidates = []
        for rec in candidates[: max(1, min(8, limit + 3))]:
            persisted_candidates.append(
                self.tracking.save_recommendation_event(rec["id"], day, rec["meal_type"], source, rec)
            )
        candidates = persisted_candidates

        return {
            "date": day,
            "remaining": remaining,
            "preferences": {
                "tastes": tastes,
                "meal_types": meal_types,
                "platform": platform,
                "budget": budget,
                "delivery_time": delivery_time,
                "restrictions": restrictions,
            },
            "source": source,
            "platform_status": {
                "eleme": "not_configured",
                "note": "饿了么开放平台需要 geo、keyword 和签名鉴权；当前先用本地营养规则生成可下单草稿。",
            },
            "recommendations": candidates[:limit],
            "more_options": candidates[limit:limit + 3],
        }

    def _extract_memory_terms(self, message: str, markers: list[str]) -> list[str]:
        terms: list[str] = []
        for marker in markers:
            if marker not in message:
                continue
            segment = message.split(marker, 1)[1]
            segment = re.split(r"[。.;；\n]", segment, 1)[0]
            for item in re.split(r"[、，,和/]", segment):
                cleaned = re.sub(r"(可以吗|行吗|谢谢|以后|都|尽量|一点|一些|的|了)$", "", item.strip())
                if 1 <= len(cleaned) <= 12:
                    terms.append(cleaned)
        return list(dict.fromkeys(terms))[:6]

    def _preference_action_from_message(self, message: str) -> dict | None:
        current = self.tracking.get_user_preferences()
        avoid = self._extract_memory_terms(message, ["不吃", "不要", "避免", "忌口", "过敏"])
        likes = self._extract_memory_terms(message, ["喜欢", "爱吃", "偏好"])
        known_tags = ["清淡", "高蛋白", "低碳", "低脂", "低糖", "少油", "少盐", "家常", "中式", "日式", "韩式", "西式"]
        taste_tags = [tag for tag in known_tags if tag in message]

        payload: dict[str, Any] = {}
        if avoid:
            payload["avoid_ingredients"] = list(dict.fromkeys([*current.get("avoid_ingredients", []), *avoid]))[:20]
        if likes or taste_tags:
            next_tags = list(dict.fromkeys([*current.get("taste_tags", []), *taste_tags, *likes]))[:20]
            payload["taste_tags"] = next_tags
        if any(key in message for key in ["中式", "日式", "韩式", "西式"]):
            cuisines = [tag for tag in ["中式", "日式", "韩式", "西式"] if tag in message]
            payload["favorite_cuisines"] = list(dict.fromkeys([*current.get("favorite_cuisines", []), *cuisines]))[:12]
        if not payload:
            return None
        return {
            "id": uuid4().hex[:10],
            "type": "save_preferences",
            "label": "记住偏好",
            "description": "把这次聊天里的忌口和口味保存到长期偏好。",
            "payload": payload,
        }

    def _macro_action_from_message(self, message: str, summary: DailySummary) -> dict | None:
        if not any(key in message for key in ["目标", "宏量", "热量", "重新计算", "调整", "减脂", "增肌", "维持"]):
            return None
        current_calories = max(1200, float(summary.calories_goal or 2000))
        lower = message.lower()
        if "增肌" in message or "bulk" in lower or "gain" in lower:
            daily_calories = current_calories * 1.08
            protein_ratio = 0.28
            fat_ratio = 0.27
            goal_label = "增肌"
        elif "维持" in message or "maintain" in lower:
            daily_calories = current_calories
            protein_ratio = 0.25
            fat_ratio = 0.28
            goal_label = "维持"
        else:
            daily_calories = current_calories * 0.9
            protein_ratio = 0.32
            fat_ratio = 0.25
            goal_label = "减脂"

        daily_calories = round(max(1200, min(4200, daily_calories)) / 10) * 10
        protein_g = round(daily_calories * protein_ratio / 4)
        if getattr(summary, "weight_kg", None):
            protein_g = max(protein_g, round(float(summary.weight_kg) * 1.6))
        fat_g = round(daily_calories * fat_ratio / 9)
        carbs_g = round(max(0, daily_calories - protein_g * 4 - fat_g * 9) / 4)
        payload = {
            "daily_calories": daily_calories,
            "protein_g": protein_g,
            "carbs_g": carbs_g,
            "fat_g": fat_g,
            "fiber_g": max(25, round(daily_calories / 1000 * 14)),
            "sugar_g": 50,
            "sodium_mg": 2300,
            "water_ml": int(getattr(summary, "hydration_goal_ml", None) or getattr(summary, "water_goal_ml", 2000) or 2000),
        }
        return {
            "id": uuid4().hex[:10],
            "type": "set_macro_goals",
            "label": f"应用{goal_label}目标",
            "description": f"{daily_calories:.0f} kcal，蛋白 {protein_g}g，碳水 {carbs_g}g，脂肪 {fat_g}g。",
            "payload": payload,
        }

    def _normalize_coach_actions(self, raw_actions: Any, fallback_actions: list[dict], recommendations: list[dict]) -> list[dict]:
        if not isinstance(raw_actions, list):
            return fallback_actions
        actions: list[dict] = []
        first_rec = recommendations[0] if recommendations else None
        for item in raw_actions:
            if isinstance(item, dict) and item.get("type"):
                actions.append(item)
            elif item == "log_recommendation" and first_rec:
                actions.append({
                    "id": uuid4().hex[:10],
                    "type": "log_recommendation",
                    "label": "记录推荐餐",
                    "description": first_rec.get("title", "记录推荐餐"),
                    "payload": {"recommendation_id": first_rec.get("id"), "meal_type": first_rec.get("meal_type")},
                })
        for action in fallback_actions:
            if not any(existing.get("type") == action.get("type") for existing in actions):
                actions.append(action)
        return actions[:4]

    def fallback_coach_reply(self, message: str, summary: DailySummary, recommendations: list[dict]) -> dict:
        remaining = self._remaining(summary)
        lower = message.lower()
        parts = []
        actions: list[dict] = []
        if remaining["calories"] <= 0:
            parts.append("今天热量已经到目标附近了，下一餐建议选清淡高蛋白、小份量。")
        else:
            parts.append(f"今天还剩约 {remaining['calories']} kcal，可以把下一餐控制在这个范围内。")
        if remaining["protein"] > 15:
            parts.append(f"蛋白质还差约 {remaining['protein']}g，优先选鸡蛋、鱼、鸡胸肉、豆腐或酸奶。")
        if "超" in message or "over" in lower:
            parts.append("如果已经超标，不需要跳餐；把后续餐改成高纤维、低油、低糖，并正常喝水。")
        if any(key in message for key in ["分析", "怎么样", "今天吃得"]):
            parts.append(f"目前蛋白 {summary.protein:.0f}/{summary.protein_goal:.0f}g，纤维 {summary.fiber:.0f}/{summary.fiber_goal:.0f}g，糖 {summary.sugar:.0f}/{summary.sugar_goal:.0f}g，钠 {summary.sodium:.0f}/{summary.sodium_goal:.0f}mg。")
        if any(key in message for key in ["替代", "换", "食谱", "推荐"]):
            parts.append("我会优先给你低油、高蛋白、能补纤维的替代方案。")
        if recommendations:
            parts.append(f"我会先推荐 {recommendations[0]['title']}，热量约 {recommendations[0]['calories']} kcal。")
            actions.append({
                "id": uuid4().hex[:10],
                "type": "log_recommendation",
                "label": "记录推荐餐",
                "description": recommendations[0].get("title", "记录推荐餐"),
                "payload": {
                    "recommendation_id": recommendations[0].get("id"),
                    "meal_type": recommendations[0].get("meal_type"),
                },
            })
        preference_action = self._preference_action_from_message(message)
        if preference_action:
            actions.append(preference_action)
            parts.append("我识别到了新的口味或忌口，可以保存为长期偏好。")
        macro_action = self._macro_action_from_message(message, summary)
        if macro_action:
            actions.append(macro_action)
            parts.append("我也算了一版新的热量和宏量目标，可以一键应用。")
        return {
            "reply": " ".join(parts),
            "actions": actions[:4],
        }

    async def coach_reply(
        self,
        message: str,
        summary: DailySummary,
        recommendations: list[dict],
        tool_context: dict | None = None,
    ) -> dict:
        fallback = self.fallback_coach_reply(message, summary, recommendations)
        if tool_context and tool_context.get("daily_summaries"):
            days = tool_context["daily_summaries"]
            total_calories = sum(float(item.get("calories_consumed") or 0) for item in days)
            total_protein = sum(float(item.get("protein") or 0) for item in days)
            average_calories = total_calories / max(1, len(days))
            fallback["reply"] = (
                f"我查了 {tool_context.get('start_date')}到{tool_context.get('end_date')} 的记录："
                f"日均约 {average_calories:.0f} 千卡，累计蛋白质 {total_protein:.0f} 克。"
                "下面的建议只基于这段真实记录。"
            )
        if not self.llm_provider:
            return {**fallback, "source": "rules", "tools_used": (tool_context or {}).get("tools_used", [])}

        safe_recs = [
            {
                "title": rec["title"],
                "calories": rec["calories"],
                "protein": rec["protein"],
                "carbs": rec["carbs"],
                "fat": rec["fat"],
                "reason": rec["reason"],
            }
            for rec in recommendations[:3]
        ]
        prompt = f"""你是中文营养教练。基于真实追踪数据回答用户，必须简短、具体、可执行。

用户问题: {message}
今日数据: 已摄入{summary.calories_consumed:.0f}kcal / 目标{summary.calories_goal:.0f}kcal,
蛋白{summary.protein:.0f}/{summary.protein_goal:.0f}g, 碳水{summary.carbs:.0f}/{summary.carbs_goal:.0f}g, 脂肪{summary.fat:.0f}/{summary.fat_goal:.0f}g。
可推荐餐: {json.dumps(safe_recs, ensure_ascii=False)}
按用户问题调用的真实记录工具结果: {json.dumps(tool_context or {}, ensure_ascii=False)}

返回JSON: {{"reply":"...", "actions":["log_recommendation"]}}。
只回答用户问到的日期和类型，不要把其他历史塞进答案，不要发明新的营养数字。"""
        try:
            text = await self.llm_provider.raw_completion("你是严谨的营养教练，只返回JSON。", prompt, max_tokens=768)
            data = self._parse_json_object(text)
            reply = str(data.get("reply") or fallback["reply"])
            actions = self._normalize_coach_actions(data.get("actions"), fallback["actions"], recommendations)
            return {
                "reply": reply,
                "actions": actions,
                "source": "ai_enhanced",
                "tools_used": (tool_context or {}).get("tools_used", []),
            }
        except Exception:
            return {**fallback, "source": "rules", "tools_used": (tool_context or {}).get("tools_used", [])}

    def _load_food_candidates(self) -> list[Food]:
        now = time.monotonic()
        if self._candidate_cache and now - self._candidate_cache_at < self._candidate_cache_ttl_seconds:
            return list(self._candidate_cache)

        with self.food_db._get_conn() as conn:
            rows = conn.execute(
                """SELECT * FROM foods
                   WHERE calories > 5
                     AND (source IS NULL OR source = '' OR source IN ('USDA / Harvard', 'user_fix', 'user'))
                   ORDER BY
                     CASE source WHEN 'user_fix' THEN 0 WHEN 'USDA / Harvard' THEN 1 ELSE 2 END,
                     name
                   LIMIT 500"""
            ).fetchall()
        foods = []
        for row in rows:
            try:
                foods.append(self.food_db._row_to_food(row))
            except Exception:
                continue
        self._candidate_cache = foods
        self._candidate_cache_at = now
        return foods

    def _filter_candidates(self, foods: list[Food], preferences: dict) -> list[Food]:
        blocked = []
        for key in ["allergies", "avoid_ingredients"]:
            blocked.extend(str(v).strip().lower() for v in preferences.get(key, []) if str(v).strip())
        diet_type = str(preferences.get("diet_type") or "balanced")

        result = []
        for food in foods:
            name = food.name.lower()
            if any(term and term in name for term in blocked):
                continue
            if diet_type in ("vegetarian", "vegan") and any(term in name for term in self.MEAT_KEYWORDS):
                continue
            if diet_type == "vegan" and any(term in name for term in ["蛋", "奶", "egg", "milk", "yogurt"]):
                continue
            result.append(food)
        return result

    def _build_recommendations(
        self,
        foods: list[Food],
        summary: DailySummary,
        remaining: dict,
        target: int,
        meal_type: str,
        preferences: dict,
        limit: int,
    ) -> list[dict]:
        groups = {
            "protein": self._top_by_category(foods, self.PROTEIN_KEYWORDS, lambda f: f.protein * 5 - f.fat),
            "carb": self._top_by_category(foods, self.CARB_KEYWORDS, lambda f: f.fiber * 3 - f.fat),
            "vegetable": self._top_by_category(foods, self.VEGETABLE_KEYWORDS, lambda f: f.fiber * 5 - f.calories / 100),
            "fruit": self._top_by_category(foods, self.FRUIT_KEYWORDS, lambda f: f.fiber * 3 - f.added_sugar * 5),
            "snack": self._top_by_category(foods, self.SNACK_KEYWORDS, lambda f: f.protein * 3 + f.fiber * 2 - f.calories / 80),
        }
        fallback = sorted(foods, key=lambda f: (abs(f.calories - target), -f.protein))[:20]
        recs = []
        used_titles = set()

        for idx in range(limit * 3):
            if meal_type == "snack":
                components = [
                    self._pick(groups["snack"] or groups["fruit"] or fallback, idx),
                    self._pick(groups["fruit"] or fallback, idx + 1),
                ]
                grams = [120, 100]
            elif meal_type == "breakfast":
                components = [
                    self._pick(groups["carb"] or fallback, idx),
                    self._pick(groups["protein"] or groups["snack"] or fallback, idx + 1),
                    self._pick(groups["fruit"] or fallback, idx + 2),
                ]
                grams = [120, 120, 100]
            else:
                components = [
                    self._pick(groups["protein"] or fallback, idx),
                    self._pick(groups["carb"] or fallback, idx + 1),
                    self._pick(groups["vegetable"] or groups["fruit"] or fallback, idx + 2),
                ]
                grams = [150, 140, 180]

            components = [food for food in components if food]
            if not components:
                continue
            rec = self._compose_recommendation(components, grams[:len(components)], target, meal_type, preferences, remaining)
            if rec["title"] in used_titles:
                continue
            used_titles.add(rec["title"])
            recs.append(rec)
            if len(recs) >= limit:
                break
        return recs

    def _compose_recommendation(
        self,
        components: list[Food],
        grams: list[int],
        target: int,
        meal_type: str,
        preferences: dict,
        remaining: dict,
    ) -> dict:
        foods = [self._scale_food(food, grams[idx]) for idx, food in enumerate(components)]
        total_cal = sum(f["calories"] for f in foods)
        scale = 1.0
        if total_cal > 0:
            scale = max(0.6, min(1.45, target / total_cal))
        foods = [self._scale_food_dict(f, scale) for f in foods]
        total_cal = round(sum(f["calories"] for f in foods))
        protein = round(sum(f["protein"] for f in foods))
        carbs = round(sum(f["carbs"] for f in foods))
        fat = round(sum(f["fat"] for f in foods))
        fiber = round(sum(f["fiber"] for f in foods), 1)
        sugar = round(sum(f["sugar"] for f in foods), 1)
        sodium = round(sum(f["sodium"] for f in foods))
        added_sugar = round(sum(f["added_sugar"] for f in foods), 1)
        names = [f["name"] for f in foods]
        meal_label = self.MEAL_LABELS.get(meal_type, "下一餐")
        prep = preferences.get("prep_time_minutes", 20)
        reason_bits = [f"贴合{meal_label}约 {target} 千卡的预算"]
        if remaining["protein"] > 15:
            reason_bits.append("优先补蛋白")
        if preferences.get("taste_tags"):
            reason_bits.append(f"偏向{preferences['taste_tags'][0]}口味")
        return {
            "id": uuid4().hex[:12],
            "title": f"{meal_label}：{' + '.join(names[:3])}",
            "meal_type": meal_type,
            "calories": total_cal,
            "protein": protein,
            "carbs": carbs,
            "fat": fat,
            "fiber": fiber,
            "sugar": sugar,
            "added_sugar": added_sugar,
            "sodium": sodium,
            "serving_size": " + ".join(f["serving_size"] for f in foods),
            "prep_time_minutes": min(int(prep or 20), 60),
            "reason": "，".join(reason_bits) + "。",
            "fit": {
                "remaining_calories_after_log": round(remaining["calories"] - total_cal),
                "protein_gap_after_log": round(max(0, remaining["protein"] - protein)),
            },
            "portion_multiplier": 1,
            "foods": foods,
        }

    def _scale_food(self, food: Food, grams: float) -> dict:
        ratio = grams / 100
        return {
            "id": uuid4().hex[:12],
            "name": self._localized_food_name(food.name),
            "calories": round(food.calories * ratio, 1),
            "protein": round(food.protein * ratio, 1),
            "carbs": round(food.carbs * ratio, 1),
            "fat": round(food.fat * ratio, 1),
            "fiber": round(food.fiber * ratio, 1),
            "sugar": round(food.sugar * ratio, 1),
            "sodium": round(food.sodium * ratio, 1),
            "added_sugar": round(food.added_sugar * ratio, 1),
            "sat_fat": round(food.sat_fat * ratio, 1),
            "trans_fat": round(food.trans_fat * ratio, 1),
            "cholesterol": round(food.cholesterol * ratio, 1),
            "vitamin_a": round(food.vitamin_a * ratio, 1),
            "vitamin_c": round(food.vitamin_c * ratio, 1),
            "calcium": round(food.calcium * ratio, 1),
            "iron": round(food.iron * ratio, 1),
            "potassium": round(food.potassium * ratio, 1),
            "serving_size": f"{round(grams)}g",
            "processing_level": food.processing_level.value if hasattr(food.processing_level, "value") else str(food.processing_level),
        }

    def _localized_food_name(self, name: str) -> str:
        text = str(name or "").strip()
        if not text:
            return "推荐食物"
        if re.search(r"[\u4e00-\u9fff]", text):
            return text
        lower = text.lower()
        for key, value in self.EN_NAME_ALIASES:
            if key in lower:
                return value
        cleaned = re.sub(r"[_\\-]+", " ", text)
        cleaned = re.sub(r"\s+", " ", cleaned).strip()
        return cleaned[:28] if cleaned else "推荐食物"

    def _scale_food_dict(self, food: dict, multiplier: float) -> dict:
        scaled = dict(food)
        grams = self._extract_grams(str(food.get("serving_size") or "100g")) * multiplier
        for field in [
            "calories", "protein", "carbs", "fat", "fiber", "sugar",
            "sodium", "added_sugar", "sat_fat", "trans_fat", "cholesterol",
            "vitamin_a", "vitamin_c", "calcium", "iron", "potassium",
        ]:
            scaled[field] = round(float(food.get(field) or 0) * multiplier, 1)
        scaled["serving_size"] = f"{round(grams)}g"
        return scaled

    async def _enhance_with_ai(self, recommendations: list[dict], summary: DailySummary, preferences: dict, meal_type: str) -> list[dict]:
        compact = [
            {
                "id": rec["id"],
                "title": rec["title"],
                "calories": rec["calories"],
                "protein": rec["protein"],
                "carbs": rec["carbs"],
                "fat": rec["fat"],
                "reason": rec["reason"],
            }
            for rec in recommendations
        ]
        prompt = f"""请润色以下餐食推荐的标题和理由，保持营养数字不变。
用户偏好: {json.dumps(preferences, ensure_ascii=False)}
餐次: {self.MEAL_LABELS.get(meal_type, meal_type)}
今日: {summary.calories_consumed:.0f}/{summary.calories_goal:.0f} kcal
推荐: {json.dumps(compact, ensure_ascii=False)}

只返回JSON: {{"items":[{{"id":"原id","title":"短标题","reason":"一句中文理由"}}]}}"""
        text = await self.llm_provider.raw_completion("你是营养产品文案助手，只返回JSON。", prompt, max_tokens=1024)
        data = self._parse_json_object(text)
        items = {item.get("id"): item for item in data.get("items", []) if isinstance(item, dict)}
        enhanced = []
        for rec in recommendations:
            item = items.get(rec["id"])
            if item:
                rec = {**rec}
                rec["title"] = str(item.get("title") or rec["title"])[:80]
                rec["reason"] = str(item.get("reason") or rec["reason"])[:220]
            enhanced.append(rec)
        return enhanced

    def _remaining(self, summary: DailySummary) -> dict:
        return {
            "calories": round(summary.calories_goal - summary.calories_consumed),
            "protein": round(max(0, summary.protein_goal - summary.protein)),
            "carbs": round(max(0, summary.carbs_goal - summary.carbs)),
            "fat": round(max(0, summary.fat_goal - summary.fat)),
        }

    def _target_calories(self, summary: DailySummary, remaining: dict, meal_type: str) -> int:
        ratio = self.MEAL_RATIOS.get(meal_type, 0.3)
        planned = summary.calories_goal * ratio
        if remaining["calories"] <= 0:
            return 220 if meal_type == "snack" else 320
        lower = 120 if meal_type == "snack" else 280
        upper = 320 if meal_type == "snack" else 850
        return round(max(lower, min(upper, min(remaining["calories"], planned))))

    def _normalize_meal_type(self, meal_type: str | None) -> str:
        if meal_type in self.MEAL_RATIOS:
            return meal_type
        hour = __import__("datetime").datetime.now().hour
        if hour < 10:
            return "breakfast"
        if hour < 15:
            return "lunch"
        if hour < 21:
            return "dinner"
        return "snack"

    def _top_by_category(self, foods: list[Food], keywords: list[str], scorer) -> list[Food]:
        matches = [food for food in foods if any(k.lower() in food.name.lower() for k in keywords)]
        less_processed = [
            food for food in matches
            if str(food.processing_level.value if hasattr(food.processing_level, "value") else food.processing_level) != "ultra_processed"
        ]
        pool = less_processed if len(less_processed) >= 3 else matches
        return sorted(pool, key=lambda food: scorer(food) - self._processing_penalty(food), reverse=True)[:24]

    def _processing_penalty(self, food: Food) -> float:
        level = str(food.processing_level.value if hasattr(food.processing_level, "value") else food.processing_level)
        if level == "ultra_processed":
            return 30
        if level == "processed":
            return 10
        return 0

    def _pick(self, foods: list[Food], index: int) -> Food | None:
        if not foods:
            return None
        return foods[index % len(foods)]

    def _extract_grams(self, text: str) -> float:
        match = re.search(r"(\d+(?:\.\d+)?)\s*(?:g|克)", text, re.IGNORECASE)
        return float(match.group(1)) if match else 100

    def _scale_serving_text(self, text: str, multiplier: float) -> str:
        grams = self._extract_grams(text)
        return f"{round(grams * multiplier)}g"

    def _clean_delivery_term(self, text: str) -> str:
        text = str(text or "")
        lower = text.lower()
        aliases = [
            ("chicken breast", "鸡胸肉"),
            ("white rice", "米饭"),
            ("brown rice", "糙米饭"),
            ("broccoli", "西兰花"),
            ("beef", "牛肉"),
            ("salmon", "三文鱼"),
            ("shrimp", "虾仁"),
            ("tofu", "豆腐"),
            ("egg", "鸡蛋"),
            ("yogurt", "酸奶"),
            ("oat", "燕麦"),
        ]
        for key, value in aliases:
            if key in lower:
                return value
        text = re.sub(r"^[^:：]+[:：]\s*", "", text)
        text = re.sub(r"\s+", " ", text).strip()
        text = re.sub(r"[+＋/、，,].*$", "", text)
        text = re.sub(r"\d+(?:\.\d+)?\s*(?:g|克|kcal|千卡)", "", text, flags=re.IGNORECASE)
        return text[:18]

    def _delivery_restaurant_hint(self, recommendation: dict, items: list[dict]) -> str:
        names = " ".join([str(recommendation.get("title") or ""), *[item["name"] for item in items]]).lower()
        if any(term in names for term in ["沙拉", "salad", "酸奶", "yogurt"]):
            return "轻食沙拉"
        if any(term in names for term in ["面", "noodle"]):
            return "健康面馆"
        if any(term in names for term in ["饭", "rice", "米"]):
            return "低油盖饭"
        if any(term in names for term in ["鸡", "牛", "鱼", "虾", "chicken", "beef", "fish", "shrimp", "tofu", "豆腐"]):
            return "高蛋白简餐"
        return "家常健康餐"

    def _delivery_templates(self) -> list[dict]:
        return [
            {
                "title": "香煎鸡胸轻食碗",
                "restaurant": "晴日轻食",
                "tags": ["清淡", "西式轻食", "轻食", "沙拉", "正餐", "断食后第一餐", "高蛋白"],
                "calories": 520, "protein": 42, "carbs": 48, "fat": 14, "fiber": 8, "sugar": 6, "sodium": 560,
                "price": 29, "delivery_minutes": 35, "note": "酱料减半，米饭正常即可。",
            },
            {
                "title": "番茄牛肉糙米饭",
                "restaurant": "轻卡家常饭",
                "tags": ["番茄", "中式家常", "米饭套餐", "正餐", "高蛋白"],
                "calories": 610, "protein": 39, "carbs": 72, "fat": 16, "fiber": 7, "sugar": 8, "sodium": 680,
                "price": 32, "delivery_minutes": 38, "note": "少油，米饭正常，不额外加汤汁。",
            },
            {
                "title": "藤椒鸡丝荞麦面",
                "restaurant": "小满面馆",
                "tags": ["香辣", "麻辣", "咸鲜", "面/粉", "正餐", "高蛋白"],
                "calories": 560, "protein": 34, "carbs": 68, "fat": 13, "fiber": 6, "sugar": 5, "sodium": 760,
                "price": 26, "delivery_minutes": 31, "note": "辣油减半，汤少喝，保留鸡丝。",
            },
            {
                "title": "酸辣鸡胸魔芋粉",
                "restaurant": "热量友好粉面",
                "tags": ["酸辣", "面/粉", "正餐", "低碳水", "高蛋白"],
                "calories": 430, "protein": 36, "carbs": 34, "fat": 12, "fiber": 9, "sugar": 4, "sodium": 720,
                "price": 24, "delivery_minutes": 29, "note": "少油少盐，魔芋粉正常，酸辣汁半份。",
            },
            {
                "title": "麻辣烫高蛋白组合",
                "restaurant": "清汤麻辣烫",
                "tags": ["麻辣", "香辣", "麻辣烫", "正餐", "高蛋白"],
                "calories": 590, "protein": 45, "carbs": 52, "fat": 18, "fiber": 10, "sugar": 5, "sodium": 940,
                "price": 34, "delivery_minutes": 42, "note": "清汤底，少麻酱，多青菜，加鸡蛋和豆腐。",
            },
            {
                "title": "咖喱鸡肉杂粮饭",
                "restaurant": "能量简餐",
                "tags": ["咖喱", "米饭套餐", "正餐", "高蛋白"],
                "calories": 650, "protein": 38, "carbs": 78, "fat": 18, "fiber": 6, "sugar": 7, "sodium": 700,
                "price": 36, "delivery_minutes": 43, "note": "咖喱酱少一半，米饭正常，优先杂粮饭。",
            },
            {
                "title": "韩式牛肉拌饭轻油版",
                "restaurant": "首尔拌饭",
                "tags": ["韩式", "酱香", "米饭套餐", "正餐", "高蛋白"],
                "calories": 630, "protein": 36, "carbs": 76, "fat": 17, "fiber": 7, "sugar": 8, "sodium": 820,
                "price": 35, "delivery_minutes": 36, "note": "拌饭酱半份，不加额外芝士。",
            },
            {
                "title": "日式照烧鸡腿饭",
                "restaurant": "和风便当",
                "tags": ["日式", "酱香", "米饭套餐", "正餐"],
                "calories": 690, "protein": 35, "carbs": 82, "fat": 22, "fiber": 5, "sugar": 10, "sodium": 780,
                "price": 33, "delivery_minutes": 34, "note": "照烧汁另放，鸡皮少吃。",
            },
            {
                "title": "便利店鸡胸酸奶组合",
                "restaurant": "便利店即食",
                "tags": ["便利店", "加餐", "清淡", "高蛋白", "断食后第一餐"],
                "calories": 390, "protein": 34, "carbs": 38, "fat": 8, "fiber": 4, "sugar": 12, "sodium": 520,
                "price": 28, "delivery_minutes": 20, "note": "选无糖酸奶，饭团半个或小份。",
            },
            {
                "title": "无糖茶 + 蛋白棒加餐",
                "restaurant": "便利店即食",
                "tags": ["奶茶/饮品", "便利店", "加餐", "控糖友好", "高蛋白"],
                "calories": 260, "protein": 22, "carbs": 26, "fat": 7, "fiber": 6, "sugar": 3, "sodium": 260,
                "price": 22, "delivery_minutes": 18, "note": "饮品选无糖，蛋白棒看糖醇耐受。",
            },
        ]

    def _delivery_option_allowed(
        self,
        template: dict,
        tastes: list[str],
        meal_types: list[str],
        restrictions: list[str],
    ) -> bool:
        tags = set(template["tags"])
        title = template["title"]
        restriction_blocks = {
            "不吃辣": ["香辣", "酸辣", "麻辣"],
            "不吃猪肉": ["猪"],
            "不吃牛肉": ["牛"],
            "不吃海鲜": ["虾", "鱼", "海鲜"],
            "不吃香菜": ["香菜"],
            "低碳水": [],
            "高蛋白": [],
            "少油": [],
            "少糖": [],
            "少盐": [],
            "控糖友好": [],
        }
        for restriction in restrictions:
            if any(term and (term in title or term in tags) for term in restriction_blocks.get(restriction, [])):
                return False
        visible_types = [item for item in meal_types if item != "高蛋白"]
        if visible_types and not tags.intersection(visible_types):
            return False
        return True

    def _compose_delivery_option(
        self,
        template: dict,
        summary: DailySummary,
        remaining: dict,
        target: int,
        tastes: list[str],
        meal_types: list[str],
        restrictions: list[str],
        platform: str,
        budget: str,
        delivery_time: str,
        fasting_status: dict | None = None,
    ) -> dict:
        tags = set(template["tags"])
        price = float(template["price"])
        minutes = int(template["delivery_minutes"])
        budget_cap = {"20 元内": 20, "20-35 元": 35, "35-50 元": 50, "不限": 999}.get(budget, 35)
        time_cap = {"30 分钟内": 30, "45 分钟内": 45, "不限": 999}.get(delivery_time, 45)
        rule_score = 74
        rule_score += max(0, 14 - abs(template["calories"] - target) / 35)
        rule_score += min(12, template["protein"] / max(1, max(25, remaining["protein"])) * 9)
        if tastes and tags.intersection(tastes):
            rule_score += 6
        if meal_types and tags.intersection(meal_types):
            rule_score += 6
        if price <= budget_cap:
            rule_score += 5
        if minutes <= time_cap:
            rule_score += 4
        if "高蛋白" in restrictions or "高蛋白" in meal_types:
            rule_score += min(6, template["protein"] / 8)
        if "低碳水" in restrictions:
            rule_score += max(0, 6 - template["carbs"] / 12)
        if "少盐" in restrictions:
            rule_score += max(0, 5 - template["sodium"] / 220)
        if "少糖" in restrictions or "控糖友好" in restrictions:
            rule_score += max(0, 5 - template["sugar"] / 3)

        provider = platform if platform in ("meituan", "eleme") else ("eleme" if "韩式" in tags or "日式" in tags else "meituan")
        platform_label = self.DELIVERY_PLATFORM_LABELS.get(provider, "美团")
        recommendation_id = uuid4().hex[:12]
        food = {
            "id": uuid4().hex[:12],
            "name": template["title"],
            "calories": template["calories"],
            "protein": template["protein"],
            "carbs": template["carbs"],
            "fat": template["fat"],
            "fiber": template["fiber"],
            "sugar": template["sugar"],
            "sodium": template["sodium"],
            "added_sugar": 0,
            "sat_fat": 0,
            "trans_fat": 0,
            "cholesterol": 0,
            "vitamin_a": 0,
            "vitamin_c": 0,
            "calcium": 0,
            "iron": 0,
            "potassium": 0,
            "serving_size": "1份",
            "processing_level": "minimally_processed",
        }
        reason = (
            f"符合你今天剩余热量，蛋白质补充效率高"
            f"{'，适合作为断食后第一餐' if '断食后第一餐' in tags else ''}。"
        )
        decision = None
        if self.decision_service:
            decision = self.decision_service.score_nutrition_dict(
                {
                    "calories": template["calories"],
                    "protein": template["protein"],
                    "carbs": template["carbs"],
                    "fat": template["fat"],
                    "fiber": template["fiber"],
                    "sugar": template["sugar"],
                    "sodium": template["sodium"],
                    "added_sugar": 0,
                    "sat_fat": 0,
                    "trans_fat": 0,
                    "cholesterol": 0,
                    "vitamin_a": 0,
                    "vitamin_c": 0,
                    "calcium": 0,
                    "iron": 0,
                    "potassium": 0,
                },
                summary=summary,
                fasting_status=fasting_status,
                preferences={
                    "tastes": tastes,
                    "meal_types": meal_types,
                    "restrictions": restrictions,
                    "platform": platform,
                    "budget": budget,
                    "delivery_time": delivery_time,
                },
                source="delivery",
                event_type="today_fit",
                names=[template["title"]],
                persist=False,
            )

        final_score = round(min(99, max(40, (rule_score * 0.35) + ((decision or {}).get("score", rule_score) * 0.65))))
        return {
            "id": recommendation_id,
            "recommendation_id": recommendation_id,
            "title": template["title"],
            "restaurant_name": template["restaurant"],
            "platform": provider,
            "platform_label": platform_label,
            "meal_type": "snack" if "加餐" in tags or "奶茶/饮品" in tags else "dinner",
            "calories": template["calories"],
            "protein": template["protein"],
            "carbs": template["carbs"],
            "fat": template["fat"],
            "fiber": template["fiber"],
            "sugar": template["sugar"],
            "sodium": template["sodium"],
            "serving_size": "1份",
            "prep_time_minutes": minutes,
            "delivery_minutes": minutes,
            "price_yuan": price,
            "score": final_score,
            "today_fit_score": (decision or {}).get("score", final_score),
            "decision": decision,
            "reason": reason,
            "score_reasons": (decision or {}).get("reasons", []),
            "warnings": (decision or {}).get("warnings", []),
            "suggestions": (decision or {}).get("suggestions", []),
            "order_note": template["note"],
            "source": "delivery_rules",
            "portion_multiplier": 1,
            "foods": [food],
            "tags": sorted(tags),
            "fit": {
                "remaining_calories_after_log": round(remaining["calories"] - template["calories"]),
                "protein_gap_after_log": round(max(0, remaining["protein"] - template["protein"])),
            },
        }

    def _parse_json_object(self, text: str) -> dict:
        cleaned = re.sub(r"```(?:json)?\s*", "", text.strip()).replace("```", "").strip()
        return json.loads(cleaned)
