"""Nutrition decision service.

Combines Cal-style tracking, Fastic-style fasting context, and Yuka-style
pre-eating product judgment into one rule-backed scoring contract.
"""

from __future__ import annotations

from datetime import date, datetime, timedelta
from typing import Any
from uuid import uuid4

from models.food import Food
from models.tracking import DailySummary


class DecisionService:
    """Scores meals, products, and next-meal choices against today's goal."""

    def __init__(self, tracking: Any | None = None):
        self.tracking = tracking

    def build_context(
        self,
        summary: DailySummary,
        fasting_status: dict | None = None,
        preferences: dict | None = None,
        history: dict | None = None,
    ) -> dict:
        fasting_status = fasting_status or {}
        preferences = preferences or {}
        remaining = self._remaining(summary)
        window = self._eating_window(fasting_status)
        active = fasting_status.get("active_session") or None
        is_fasting = bool(active)
        can_eat = bool(window["can_eat"])
        current_stage = fasting_status.get("current_stage") or (active or {}).get("stage") or None
        protein_gap = remaining["protein"]
        suggested = self._suggested_next_meal(remaining, is_fasting, can_eat)
        avoid = self._not_recommended(remaining)
        day_score = self._score_day(summary, remaining, fasting_status)
        adaptive = self._adaptive_fasting_advice(fasting_status, history)

        coach_cards = [
            {
                "id": "can_eat",
                "title": "现在能不能吃",
                "body": window["advice"],
                "status": "ok" if can_eat else "wait",
            },
            {
                "id": "next_meal",
                "title": "下一餐方向",
                "body": suggested,
                "status": "ok",
            },
        ]
        if adaptive:
            coach_cards.append({"id": "fasting_adjustment", **adaptive})

        return {
            "date": summary.date or date.today().isoformat(),
            "remaining": remaining,
            "eating_window": window,
            "can_eat": can_eat,
            "is_fasting": is_fasting,
            "current_stage": current_stage,
            "suggested_next_meal": suggested,
            "not_recommended": avoid,
            "protein_gap": protein_gap,
            "day_score": day_score,
            "coach_cards": coach_cards,
            "adaptive_fasting": adaptive,
            "preferences": preferences,
        }

    def score_foods(
        self,
        foods: list[Food],
        summary: DailySummary,
        fasting_status: dict | None = None,
        preferences: dict | None = None,
        source: str = "meal",
        event_type: str = "meal_score",
        persist: bool = False,
    ) -> dict:
        payload = self._score_nutrition(
            nutrition=self._sum_foods(foods),
            names=[food.name for food in foods],
            summary=summary,
            fasting_status=fasting_status,
            preferences=preferences,
            source=source,
            event_type=event_type,
            items=[self._food_payload(food) for food in foods],
        )
        if persist and self.tracking:
            self.tracking.save_decision_event(
                payload["id"],
                payload["date"],
                event_type,
                source,
                payload["score"],
                payload["headline"],
                payload,
            )
        return payload

    def score_nutrition_dict(
        self,
        nutrition: dict,
        summary: DailySummary,
        fasting_status: dict | None = None,
        preferences: dict | None = None,
        source: str = "candidate",
        event_type: str = "today_fit",
        names: list[str] | None = None,
        persist: bool = False,
    ) -> dict:
        payload = self._score_nutrition(
            nutrition={key: float(nutrition.get(key, 0) or 0) for key in self._nutrition_fields()},
            names=names or [],
            summary=summary,
            fasting_status=fasting_status,
            preferences=preferences,
            source=source,
            event_type=event_type,
            items=[],
        )
        if persist and self.tracking:
            self.tracking.save_decision_event(
                payload["id"],
                payload["date"],
                event_type,
                source,
                payload["score"],
                payload["headline"],
                payload,
            )
        return payload

    def _score_nutrition(
        self,
        nutrition: dict,
        names: list[str],
        summary: DailySummary,
        fasting_status: dict | None,
        preferences: dict | None,
        source: str,
        event_type: str,
        items: list[dict],
    ) -> dict:
        context = self.build_context(summary, fasting_status, preferences)
        calories = nutrition["calories"]
        protein = nutrition["protein"]
        carbs = nutrition["carbs"]
        fat = nutrition["fat"]
        fiber = nutrition["fiber"]
        sugar = nutrition["sugar"]
        added_sugar = nutrition["added_sugar"]
        sodium = nutrition["sodium"]
        sat_fat = nutrition["sat_fat"]
        trans_fat = nutrition["trans_fat"]
        remaining = context["remaining"]

        target = self._target_calories(remaining, event_type, calories)
        calorie_score = self._score_distance(calories, target, max(120, target * 0.42))
        protein_score = self._score_at_least(protein, min(45, max(18, remaining["protein"] * 0.75 if remaining["protein"] else 25)))
        fat_score = self._score_at_most(fat, max(14, calories * 0.34 / 9 if calories else 18))
        sugar_score = self._score_at_most(max(sugar, added_sugar * 1.4), 10 if source in ("barcode", "label", "product") else 14)
        sodium_score = self._score_at_most(sodium, 700 if calories >= 350 else 420)
        fiber_score = self._score_at_least(fiber, 5 if calories >= 350 else 3)
        sat_fat_score = self._score_at_most(sat_fat + trans_fat * 4, 6)
        processing_score = self._processing_score(items, source)
        fasting_score = self._fasting_score(context, calories, sugar, fat, event_type)

        if source in ("barcode", "label", "product", "barcode_scan", "barcode_camera"):
            weights = {
                "processing": 0.23,
                "sugar": 0.18,
                "sodium": 0.13,
                "sat_fat": 0.12,
                "protein": 0.12,
                "fiber": 0.08,
                "calorie_fit": 0.08,
                "fasting": 0.06,
            }
            score = (
                processing_score * weights["processing"]
                + sugar_score * weights["sugar"]
                + sodium_score * weights["sodium"]
                + sat_fat_score * weights["sat_fat"]
                + protein_score * weights["protein"]
                + fiber_score * weights["fiber"]
                + calorie_score * weights["calorie_fit"]
                + fasting_score * weights["fasting"]
            )
            score_type = "packaged_health_score"
        elif event_type == "after_log":
            score = (
                calorie_score * 0.20
                + protein_score * 0.22
                + fat_score * 0.14
                + sugar_score * 0.12
                + sodium_score * 0.10
                + fiber_score * 0.10
                + processing_score * 0.08
                + fasting_score * 0.04
            )
            score_type = "meal_nutrition_score"
        else:
            score = (
                calorie_score * 0.24
                + protein_score * 0.24
                + fat_score * 0.12
                + sugar_score * 0.10
                + sodium_score * 0.10
                + fiber_score * 0.08
                + processing_score * 0.06
                + fasting_score * 0.06
            )
            score_type = "today_fit_score"

        rounded = int(max(0, min(100, round(score))))
        criteria = [
            self._criterion("热量适配", calorie_score, f"约 {round(calories)} kcal，目标本餐约 {round(target)} kcal"),
            self._criterion("蛋白补缺", protein_score, f"蛋白质 {round(protein, 1)}g，今日还差 {remaining['protein']}g"),
            self._criterion("油脂风险", fat_score, f"脂肪 {round(fat, 1)}g，饱和/反式脂肪 {round(sat_fat + trans_fat, 1)}g"),
            self._criterion("糖风险", sugar_score, f"糖 {round(sugar, 1)}g，添加糖 {round(added_sugar, 1)}g"),
            self._criterion("钠风险", sodium_score, f"钠 {round(sodium)}mg"),
            self._criterion("饱腹感", fiber_score, f"膳食纤维 {round(fiber, 1)}g"),
            self._criterion("加工度", processing_score, self._processing_detail(items, source)),
            self._criterion("断食适配", fasting_score, context["eating_window"]["advice"]),
        ]
        reasons, warnings, suggestions = self._explain(
            score=rounded,
            nutrition=nutrition,
            context=context,
            criteria=criteria,
            source=source,
            event_type=event_type,
        )
        label = self._score_label(rounded)
        headline = self._headline(label, source, event_type, names)

        return {
            "id": uuid4().hex[:12],
            "date": summary.date or date.today().isoformat(),
            "score": rounded,
            "score_type": score_type,
            "label": label,
            "headline": headline,
            "nutrition": {key: round(value, 2) for key, value in nutrition.items()},
            "criteria": criteria,
            "reasons": reasons,
            "warnings": warnings,
            "suggestions": suggestions,
            "next_adjustment": self._next_adjustment(nutrition, context),
            "context": context,
            "items": items,
            "source": source,
            "event_type": event_type,
            "today_fit_score": rounded if score_type == "today_fit_score" else None,
            "meal_nutrition_score": rounded if score_type == "meal_nutrition_score" else None,
            "packaged_health_score": rounded if score_type == "packaged_health_score" else None,
        }

    def _score_day(self, summary: DailySummary, remaining: dict, fasting_status: dict | None) -> dict:
        calorie_score = self._score_at_most(summary.calories_consumed, max(1, summary.calories_goal))
        protein_score = self._score_at_least(summary.protein, max(1, summary.protein_goal))
        fiber_score = self._score_at_least(summary.fiber, max(1, summary.fiber_goal))
        sugar_score = self._score_at_most(summary.sugar, max(1, summary.sugar_goal))
        sodium_score = self._score_at_most(summary.sodium, max(1, summary.sodium_goal))
        fasting_bonus = 8 if (fasting_status or {}).get("enabled") or (fasting_status or {}).get("active_session") else 0
        score = round(calorie_score * 0.28 + protein_score * 0.25 + fiber_score * 0.14 + sugar_score * 0.12 + sodium_score * 0.11 + 10 + fasting_bonus)
        score = int(max(0, min(100, score)))
        if remaining["calories"] < 200 and remaining["protein"] > 20:
            headline = "今天热量空间不多，下一餐要小份高蛋白"
        elif remaining["protein"] > 25:
            headline = "今天蛋白质缺口明显，下一餐优先补蛋白"
        else:
            headline = "今天节奏稳定，继续保持低油低糖"
        return {"score": score, "label": self._score_label(score), "headline": headline}

    def _adaptive_fasting_advice(self, fasting_status: dict, history: dict | None) -> dict | None:
        sessions = (history or {}).get("sessions") or fasting_status.get("recent_sessions") or []
        if len(sessions) < 3:
            return None
        ended_early = [item for item in sessions[:7] if item.get("status") == "ended_early"]
        completed = [item for item in sessions[:7] if item.get("status") == "completed"]
        if len(ended_early) >= 3:
            return {
                "title": "断食计划建议",
                "body": "最近提前结束较多，建议接下来 7 天先改成 14:10，把稳定打卡放在第一位。",
                "status": "adjust",
                "recommended_method": "14:10",
            }
        if len(completed) >= 5:
            return {
                "title": "断食计划建议",
                "body": "最近完成度很好，可以继续当前窗口；先不要急着加难度。",
                "status": "stable",
                "recommended_method": (fasting_status.get("preferences") or {}).get("method", "16:8"),
            }
        return None

    @staticmethod
    def _nutrition_fields() -> list[str]:
        return [
            "calories", "protein", "carbs", "fat", "fiber", "sugar", "sodium",
            "sat_fat", "trans_fat", "cholesterol", "vitamin_a", "vitamin_c",
            "calcium", "iron", "potassium", "added_sugar",
        ]

    def _sum_foods(self, foods: list[Food]) -> dict:
        return {
            field: float(sum(float(getattr(food, field, 0) or 0) for food in foods))
            for field in self._nutrition_fields()
        }

    def _food_payload(self, food: Food) -> dict:
        level = food.processing_level.value if hasattr(food.processing_level, "value") else str(food.processing_level)
        return {
            "id": food.id,
            "name": food.name,
            "serving_size": food.serving_size,
            "processing_level": level,
            **{field: float(getattr(food, field, 0) or 0) for field in self._nutrition_fields()},
        }

    def _remaining(self, summary: DailySummary) -> dict:
        return {
            "calories": round(summary.calories_goal - summary.calories_consumed),
            "protein": round(max(0, summary.protein_goal - summary.protein)),
            "carbs": round(max(0, summary.carbs_goal - summary.carbs)),
            "fat": round(max(0, summary.fat_goal - summary.fat)),
        }

    def _eating_window(self, fasting_status: dict | None) -> dict:
        fasting_status = fasting_status or {}
        prefs = fasting_status.get("preferences") or {}
        start = str(prefs.get("eating_window_start") or "12:00")
        eating_hours = float(prefs.get("eating_hours") or 8)
        end = self._add_hours(start, eating_hours)
        active = fasting_status.get("active_session") or None
        now = datetime.now().astimezone()
        if active:
            remaining = float(active.get("remaining_seconds") or 0)
            can_eat = remaining <= 0
            if can_eat:
                advice = "进食窗口已到，第一餐建议高蛋白、低油，避免空腹高糖。"
                state = "eating_window_ready"
            else:
                advice = f"还在断食中，先喝水 / 黑咖啡 / 无糖茶，剩余约 {self._format_duration(remaining)}。"
                state = "fasting"
        elif prefs.get("enabled"):
            can_eat = self._is_time_in_window(now, start, end)
            state = "in_window" if can_eat else "outside_window"
            advice = "现在在进食窗口，可以吃；优先高蛋白、低油、适量碳水。" if can_eat else f"现在不在进食窗口，建议等到 {start} 后再吃。"
        else:
            can_eat = True
            state = "no_fasting_plan"
            advice = "未开启断食计时，可以按今天剩余热量安排下一餐。"
        return {
            "start": start,
            "end": end,
            "label": f"{start} - {end}",
            "state": state,
            "can_eat": can_eat,
            "advice": advice,
        }

    def _target_calories(self, remaining: dict, event_type: str, calories: float) -> float:
        if event_type == "snack":
            return max(120, min(320, remaining["calories"] or calories or 180))
        if remaining["calories"] <= 0:
            return max(220, min(380, calories or 320))
        return max(260, min(760, remaining["calories"], calories or remaining["calories"]))

    @staticmethod
    def _score_distance(value: float, target: float, tolerance: float) -> float:
        if target <= 0:
            return 70
        penalty = abs(value - target) / max(1, tolerance) * 38
        if value > target * 1.35:
            penalty += min(22, (value - target * 1.35) / max(1, target) * 50)
        return max(0, min(100, 100 - penalty))

    @staticmethod
    def _score_at_least(value: float, target: float) -> float:
        if target <= 0:
            return 80
        return max(0, min(100, value / target * 100))

    @staticmethod
    def _score_at_most(value: float, limit: float) -> float:
        if value <= 0:
            return 100
        if limit <= 0:
            return 60
        if value <= limit:
            return 100 - (value / limit) * 16
        return max(0, 84 - ((value - limit) / limit) * 70)

    def _processing_score(self, items: list[dict], source: str) -> float:
        if not items:
            return 62 if source in ("barcode", "label", "product", "barcode_scan", "barcode_camera") else 78
        mapping = {
            "whole": 98,
            "minimally_processed": 84,
            "processed": 58,
            "ultra_processed": 28,
        }
        scores = [mapping.get(str(item.get("processing_level") or "whole"), 70) for item in items]
        return sum(scores) / max(1, len(scores))

    def _fasting_score(self, context: dict, calories: float, sugar: float, fat: float, event_type: str) -> float:
        if event_type == "after_log":
            base = 82
        elif context["can_eat"]:
            base = 92
        else:
            base = 42
        if context["eating_window"]["state"] in ("eating_window_ready", "in_window"):
            if sugar > 14:
                base -= 18
            if fat > 25:
                base -= 10
            if calories > 780:
                base -= 12
        return max(0, min(100, base))

    def _criterion(self, label: str, score: float, detail: str) -> dict:
        rounded = int(max(0, min(100, round(score))))
        if rounded >= 85:
            status = "good"
        elif rounded >= 65:
            status = "watch"
        else:
            status = "risk"
        return {"label": label, "score": rounded, "status": status, "detail": detail}

    def _explain(self, score: int, nutrition: dict, context: dict, criteria: list[dict], source: str, event_type: str) -> tuple[list[str], list[str], list[str]]:
        reasons = []
        warnings = []
        suggestions = []
        if nutrition["protein"] >= 30:
            reasons.append("蛋白质补充效率高，适合减脂期维持饱腹感。")
        elif nutrition["protein"] >= 18:
            reasons.append("蛋白质有一定补充，但还可以再加鸡蛋、豆腐或鸡胸肉。")
        if nutrition["calories"] <= max(340, context["remaining"]["calories"]):
            reasons.append("热量基本落在今天剩余空间内。")
        if nutrition["fiber"] >= 5:
            reasons.append("纤维不错，饱腹感会更稳。")

        risky = [item for item in criteria if item["status"] == "risk"]
        warnings.extend(f"{item['label']}需要调整：{item['detail']}" for item in risky[:3])
        if not context["can_eat"] and event_type != "after_log":
            warnings.insert(0, "当前仍在断食/非进食窗口，不建议立刻吃。")
        if source in ("barcode", "label", "product", "barcode_scan", "barcode_camera") and not any(item.get("processing_level") for item in nutrition.get("items", [])):
            suggestions.append("如果能拍到配料表，可以进一步识别添加剂和成分风险。")

        if nutrition["sodium"] > 700:
            suggestions.append("这一餐少喝汤汁，下一餐选低盐清淡。")
        if nutrition["sugar"] > 12 or nutrition["added_sugar"] > 6:
            suggestions.append("糖偏高，饮品改无糖，今天后面不要再加甜点。")
        if nutrition["fat"] > 24:
            suggestions.append("油脂偏高，下餐用清蒸/水煮/少酱路线。")
        if context["protein_gap"] > 20 and nutrition["protein"] < 25:
            suggestions.append("今天蛋白还差不少，建议补一份鸡蛋、酸奶、豆腐或瘦肉。")
        if score >= 85:
            suggestions.insert(0, "可以作为今天的优先选择。")
        elif score < 65:
            suggestions.insert(0, "不算理想，建议换成更高蛋白、少油少糖的选项。")

        return reasons[:4], warnings[:4], list(dict.fromkeys(suggestions))[:5]

    def _next_adjustment(self, nutrition: dict, context: dict) -> str:
        parts = []
        if nutrition["protein"] < 25 and context["protein_gap"] > 15:
            parts.append("下一餐补高蛋白")
        if nutrition["fat"] > 24:
            parts.append("下一餐少油")
        if nutrition["sodium"] > 700:
            parts.append("多喝水并少盐")
        if nutrition["sugar"] > 12:
            parts.append("后续不再加甜饮/甜点")
        if not parts:
            parts.append("下一餐保持清淡和蔬菜量")
        return "，".join(parts) + "。"

    def _suggested_next_meal(self, remaining: dict, is_fasting: bool, can_eat: bool) -> str:
        if is_fasting and not can_eat:
            return "先不吃，喝水 / 黑咖啡 / 无糖茶。"
        if remaining["calories"] < 280:
            return "小份高蛋白、低油、低糖，主食减半。"
        if remaining["protein"] > 25:
            return "高蛋白、低油、适量碳水。"
        return "清淡、蔬菜优先、主食适量。"

    @staticmethod
    def _not_recommended(remaining: dict) -> str:
        if remaining["calories"] < 350:
            return "炸物、奶茶、甜点、大份主食"
        return "炸物、奶茶、甜点"

    @staticmethod
    def _score_label(score: int) -> str:
        if score >= 90:
            return "非常适合"
        if score >= 80:
            return "适合"
        if score >= 65:
            return "可吃但要调整"
        if score >= 50:
            return "谨慎选择"
        return "不建议"

    def _headline(self, label: str, source: str, event_type: str, names: list[str]) -> str:
        name = "、".join([item for item in names if item][:2])
        if source in ("barcode", "label", "product", "barcode_scan", "barcode_camera"):
            return f"{name or '包装食品'}：{label}"
        if event_type == "after_log":
            return f"本餐营养分：{label}"
        return f"{name or '这餐'}：{label}"

    @staticmethod
    def _processing_detail(items: list[dict], source: str) -> str:
        if not items:
            return "缺少配料/加工度信息" if source in ("barcode", "label", "product", "barcode_scan", "barcode_camera") else "按普通餐食估算"
        levels = [str(item.get("processing_level") or "whole") for item in items]
        if "ultra_processed" in levels:
            return "包含超加工食品"
        if "processed" in levels:
            return "包含加工食品"
        return "加工度较低"

    @staticmethod
    def _add_hours(time_text: str, hours: float) -> str:
        try:
            hour, minute = [int(part) for part in time_text.split(":", 1)]
        except Exception:
            hour, minute = 12, 0
        total = (hour * 60 + minute + int(round(hours * 60))) % (24 * 60)
        return f"{total // 60:02d}:{total % 60:02d}"

    @staticmethod
    def _is_time_in_window(now: datetime, start: str, end: str) -> bool:
        def minutes(value: str) -> int:
            hour, minute = [int(part) for part in value.split(":", 1)]
            return hour * 60 + minute

        current = now.hour * 60 + now.minute
        start_min = minutes(start)
        end_min = minutes(end)
        if start_min <= end_min:
            return start_min <= current <= end_min
        return current >= start_min or current <= end_min

    @staticmethod
    def _format_duration(seconds: float) -> str:
        total = max(0, int(seconds))
        hours = total // 3600
        minutes = (total % 3600) // 60
        if hours:
            return f"{hours}小时{minutes}分钟"
        return f"{minutes}分钟"
