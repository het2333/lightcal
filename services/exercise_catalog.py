"""Exercise catalog and calorie estimates.

Uses MET values to estimate calories:
calories = MET * 3.5 * body_weight_kg / 200 * minutes
"""

from __future__ import annotations

from dataclasses import dataclass


DEFAULT_BODY_WEIGHT_KG = 70.0
INTENSITY_LABELS = {
    "light": "Low",
    "moderate": "Moderate",
    "vigorous": "High",
}


@dataclass(frozen=True)
class ExerciseCatalogItem:
    id: str
    name: str
    category: str
    description: str
    default_intensity: str
    suggested_minutes: int
    met: dict[str, float]
    aliases: tuple[str, ...] = ()

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "name": self.name,
            "category": self.category,
            "description": self.description,
            "default_intensity": self.default_intensity,
            "suggested_minutes": self.suggested_minutes,
            "met": self.met,
            "aliases": list(self.aliases),
        }


EXERCISE_CATALOG: list[ExerciseCatalogItem] = [
    ExerciseCatalogItem("walking", "步行", "cardio", "散步、快走、通勤步行", "moderate", 30, {"light": 2.8, "moderate": 3.8, "vigorous": 4.8}, ("walk", "快走", "散步")),
    ExerciseCatalogItem("running", "跑步", "cardio", "慢跑、配速跑、冲刺跑", "moderate", 30, {"light": 6.0, "moderate": 9.8, "vigorous": 12.8}, ("run", "jogging", "慢跑")),
    ExerciseCatalogItem("cycling", "骑行", "cardio", "室外骑行、动感单车、通勤骑车", "moderate", 45, {"light": 4.0, "moderate": 7.5, "vigorous": 10.0}, ("bike", "bicycle", "单车")),
    ExerciseCatalogItem("swimming", "游泳", "cardio", "自由泳、蛙泳、持续游泳", "moderate", 30, {"light": 5.8, "moderate": 8.3, "vigorous": 10.0}, ("swim", "泳")),
    ExerciseCatalogItem("rowing", "划船机", "cardio", "划船机、有氧划船训练", "moderate", 20, {"light": 4.8, "moderate": 7.0, "vigorous": 8.5}, ("row", "rowing")),
    ExerciseCatalogItem("elliptical", "椭圆机", "cardio", "椭圆机、低冲击有氧", "moderate", 30, {"light": 4.0, "moderate": 5.5, "vigorous": 7.0}, ("elliptical", "椭圆")),
    ExerciseCatalogItem("jump_rope", "跳绳", "cardio", "间歇跳绳、连续跳绳", "vigorous", 15, {"light": 8.0, "moderate": 10.0, "vigorous": 12.3}, ("rope", "跳绳")),
    ExerciseCatalogItem("stair_climb", "爬楼梯", "cardio", "楼梯机、爬楼、台阶训练", "moderate", 20, {"light": 4.0, "moderate": 8.0, "vigorous": 9.8}, ("stairs", "楼梯")),
    ExerciseCatalogItem("hiking", "徒步", "cardio", "户外徒步、爬坡、远足", "moderate", 60, {"light": 4.3, "moderate": 6.0, "vigorous": 7.8}, ("hike", "远足")),
    ExerciseCatalogItem("weightlifting", "举重", "strength", "器械、杠铃、哑铃、力量训练", "moderate", 45, {"light": 3.5, "moderate": 5.0, "vigorous": 6.0}, ("力量训练", "weights", "lift", "撸铁")),
    ExerciseCatalogItem("bodyweight", "自重训练", "strength", "俯卧撑、深蹲、卷腹、平板支撑", "moderate", 30, {"light": 3.8, "moderate": 5.5, "vigorous": 8.0}, ("calisthenics", "自重")),
    ExerciseCatalogItem("hiit", "HIIT", "strength", "高强度间歇、循环训练", "vigorous", 20, {"light": 6.0, "moderate": 8.5, "vigorous": 11.0}, ("tabata", "interval", "间歇")),
    ExerciseCatalogItem("pilates", "普拉提", "mobility", "核心、稳定性和控制训练", "moderate", 45, {"light": 3.0, "moderate": 3.8, "vigorous": 5.0}, ("pilates",)),
    ExerciseCatalogItem("yoga", "瑜伽", "mobility", "拉伸、流瑜伽、恢复训练", "light", 45, {"light": 2.3, "moderate": 3.0, "vigorous": 4.0}, ("yoga", "拉伸")),
    ExerciseCatalogItem("mobility", "拉伸放松", "mobility", "动态拉伸、筋膜放松、灵活性训练", "light", 20, {"light": 2.0, "moderate": 2.5, "vigorous": 3.0}, ("stretch", "stretching")),
    ExerciseCatalogItem("basketball", "篮球", "sports", "半场、全场、投篮训练", "moderate", 45, {"light": 4.5, "moderate": 6.5, "vigorous": 8.0}, ("basketball", "篮")),
    ExerciseCatalogItem("soccer", "足球", "sports", "足球训练、比赛、带球跑动", "moderate", 45, {"light": 5.0, "moderate": 7.0, "vigorous": 10.0}, ("football", "soccer", "足")),
    ExerciseCatalogItem("tennis", "网球", "sports", "单打、双打、挥拍训练", "moderate", 45, {"light": 5.0, "moderate": 7.3, "vigorous": 8.5}, ("tennis",)),
    ExerciseCatalogItem("badminton", "羽毛球", "sports", "单打、双打、对抗训练", "moderate", 45, {"light": 4.5, "moderate": 5.5, "vigorous": 7.0}, ("badminton", "羽")),
    ExerciseCatalogItem("table_tennis", "乒乓球", "sports", "乒乓球训练、娱乐对打", "moderate", 30, {"light": 3.0, "moderate": 4.0, "vigorous": 5.0}, ("ping pong", "乒乓")),
    ExerciseCatalogItem("dance", "跳舞", "daily", "舞蹈课、自由舞、燃脂舞", "moderate", 30, {"light": 3.5, "moderate": 5.0, "vigorous": 7.3}, ("dance", "舞")),
    ExerciseCatalogItem("housework", "家务", "daily", "打扫、拖地、整理房间", "moderate", 30, {"light": 2.5, "moderate": 3.5, "vigorous": 4.5}, ("cleaning", "打扫")),
]


def normalize_intensity(intensity: str | None) -> str:
    value = (intensity or "moderate").strip().lower()
    return value if value in INTENSITY_LABELS else "moderate"


def get_exercise_catalog() -> list[dict]:
    return [item.to_dict() for item in EXERCISE_CATALOG]


def find_exercise(exercise_id: str | None = None, name: str | None = None) -> ExerciseCatalogItem | None:
    exercise_id = (exercise_id or "").strip().lower()
    name_query = (name or "").strip().lower()
    for item in EXERCISE_CATALOG:
        candidates = {item.id.lower(), item.name.lower(), *(alias.lower() for alias in item.aliases)}
        if exercise_id and exercise_id in candidates:
            return item
        if name_query and any(candidate and candidate in name_query for candidate in candidates):
            return item
    return None


def estimate_exercise_calories(
    *,
    exercise_id: str | None = None,
    name: str | None = None,
    duration_minutes: int,
    intensity: str | None = "moderate",
    body_weight_kg: float | None = None,
) -> dict:
    minutes = max(1, int(duration_minutes or 1))
    normalized_intensity = normalize_intensity(intensity)
    weight = body_weight_kg if body_weight_kg and body_weight_kg > 0 else DEFAULT_BODY_WEIGHT_KG
    exercise = find_exercise(exercise_id=exercise_id, name=name)
    met_values = exercise.met if exercise else {"light": 2.5, "moderate": 4.0, "vigorous": 6.0}
    met = met_values.get(normalized_intensity) or met_values.get("moderate") or 4.0
    calories = met * 3.5 * weight / 200 * minutes
    return {
        "exercise": exercise.to_dict() if exercise else None,
        "intensity": normalized_intensity,
        "duration_minutes": minutes,
        "body_weight_kg": weight,
        "met": met,
        "calories_burned": round(calories),
    }
