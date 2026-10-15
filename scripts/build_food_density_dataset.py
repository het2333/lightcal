#!/usr/bin/env python3
"""Build app-ready food density datasets from FAO/INFOODS plus Chinese aliases."""

from __future__ import annotations

import csv
import json
import sqlite3
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
FAO_APP_READY = ROOT / "data/raw/density/faoinfoods_density_v2/parsed/faoinfoods_density_v2_app_ready.csv"
OUT_DIR = ROOT / "data/raw/density/merged"
DB_PATH = ROOT / "data/depth_meal.db"


CATEGORY_DEFAULTS = [
    ("staple", "主食", 0.55, 0.73, 0.90, "bulk_density", "FAO/INFOODS category match + app heuristic", "medium", "米饭、面、粉、谷物主食兜底"),
    ("rice", "米饭类", 0.68, 0.75, 0.85, "bulk_density", "FAO/INFOODS category match + app heuristic", "medium", "熟米饭、杂粮饭、炒饭"),
    ("noodles", "面条类", 0.55, 0.72, 0.90, "bulk_density", "FAO/INFOODS category match + app heuristic", "medium", "汤面、炒面、拌面"),
    ("porridge", "粥类", 0.95, 1.02, 1.08, "mass_density", "FAO/INFOODS category match + app heuristic", "medium", "白粥、杂粮粥、稀饭"),
    ("leafy_vegetable_raw", "生叶菜", 0.12, 0.25, 0.45, "bulk_density", "FAO/INFOODS category match + app heuristic", "low", "沙拉、生菜、叶菜蓬松体积"),
    ("vegetable_cooked", "熟蔬菜", 0.40, 0.55, 0.80, "bulk_density", "FAO/INFOODS category match + app heuristic", "medium", "清炒/水煮蔬菜"),
    ("root_vegetable", "根茎类蔬菜", 0.55, 0.75, 0.95, "bulk_density", "FAO/INFOODS category match + app heuristic", "medium", "胡萝卜、土豆、红薯、莲藕"),
    ("fruit_fresh", "新鲜水果", 0.65, 0.80, 0.95, "bulk_density", "FAO/INFOODS category match + app heuristic", "medium", "切块水果兜底"),
    ("meat_cooked", "熟肉类", 0.65, 0.85, 1.05, "bulk_density", "FAO/INFOODS category match + app heuristic", "medium", "熟猪牛羊鸡肉块"),
    ("fish_seafood_cooked", "熟鱼虾蟹贝", 0.70, 0.90, 1.10, "bulk_density", "FAO/INFOODS category match + app heuristic", "medium", "鱼虾海鲜熟制"),
    ("egg", "蛋类", 0.55, 0.65, 0.80, "bulk_density", "FAO/INFOODS category match + app heuristic", "medium", "鸡蛋、鸭蛋、蛋块"),
    ("tofu", "豆腐豆制品", 0.75, 0.90, 1.05, "bulk_density", "FAO/INFOODS category match + app heuristic", "medium", "豆腐、豆干、豆制品"),
    ("soup", "汤水", 1.00, 1.05, 1.10, "mass_density", "FAO/INFOODS Density Database V2", "high", "汤、汤底、清汤和普通汤水"),
    ("drink", "饮品", 0.99, 1.03, 1.10, "mass_density", "FAO/INFOODS Density Database V2", "high", "茶、咖啡、果汁、奶茶液体"),
    ("sauce", "酱汁蘸料", 0.95, 1.10, 1.25, "mass_density", "FAO/INFOODS category match + app heuristic", "medium", "酱油、沙拉酱、蘸料、油醋汁"),
    ("oil", "食用油", 0.88, 0.92, 0.93, "mass_density", "FAO/INFOODS Density Database V2", "high", "食用油"),
    ("fried_food", "油炸食品", 0.35, 0.65, 0.90, "bulk_density", "app heuristic", "low", "炸鸡、炸薯条、裹粉炸物"),
    ("pastry_dessert", "糕点甜品", 0.35, 0.65, 0.95, "bulk_density", "FAO/INFOODS category match + app heuristic", "medium", "蛋挞、糕点、面包、甜点"),
    ("mixed_dish", "混合菜", 0.65, 0.80, 1.00, "bulk_density", "app heuristic", "medium", "中式炒菜、盖饭菜码、便当混合菜"),
    ("hotpot_malatang_solid", "火锅麻辣烫固体", 0.55, 0.75, 0.95, "bulk_density", "app heuristic", "medium", "火锅/麻辣烫捞出的固体食材"),
]


CHINESE_HIGH_FREQUENCY = [
    ("rice_cooked", "熟米饭", "cooked rice", "主食", 0.70, 0.73, 0.80, "bulk_density", "FAO/INFOODS Density Database V2", "high", "白米饭/熟米饭"),
    ("rice_purple", "紫米饭/杂粮饭", "purple rice / mixed grain rice", "主食", 0.68, 0.75, 0.85, "bulk_density", "app heuristic", "medium", "紫米饭、黑米饭、杂粮饭"),
    ("rice_fried", "炒饭", "fried rice", "主食/混合菜", 0.68, 0.75, 0.85, "bulk_density", "FAO/INFOODS + app heuristic", "medium", "蛋炒饭、辣炒饭、扬州炒饭"),
    ("rice_congee", "粥/稀饭", "porridge / congee", "主食/汤粥", 0.95, 1.02, 1.08, "mass_density", "FAO/INFOODS + app heuristic", "medium", "白粥、杂粮粥"),
    ("noodles_boiled", "熟面条/汤面面条", "boiled noodles", "主食", 0.55, 0.59, 0.70, "bulk_density", "FAO/INFOODS Density Database V2", "high", "汤面固体面条"),
    ("noodles_fried", "炒面/拌面", "fried noodles", "主食/混合菜", 0.70, 0.80, 0.90, "bulk_density", "FAO/INFOODS + app heuristic", "medium", "炒面、拌面、油面"),
    ("rice_noodles", "米粉/河粉", "rice noodles", "主食", 0.55, 0.70, 0.85, "bulk_density", "app heuristic", "medium", "米粉、河粉、米线"),
    ("steamed_bun", "馒头", "steamed bun", "主食", 0.25, 0.35, 0.50, "bulk_density", "app heuristic", "low", "馒头、花卷"),
    ("baozi_steamed_bun", "包子", "baozi", "主食/混合菜", 0.35, 0.50, 0.70, "bulk_density", "app heuristic", "medium", "包子、肉包、菜包"),
    ("dumpling", "饺子", "dumpling", "主食/混合菜", 0.75, 0.85, 0.95, "bulk_density", "app heuristic", "medium", "水饺、蒸饺、煎饺"),
    ("wonton", "馄饨/云吞", "wonton", "主食/混合菜", 0.70, 0.85, 1.00, "bulk_density", "app heuristic", "medium", "馄饨固体部分"),
    ("bread", "面包/吐司", "bread", "主食/糕点", 0.20, 0.30, 0.45, "bulk_density", "FAO/INFOODS + app heuristic", "medium", "吐司、餐包"),
    ("corn_cooked", "玉米", "cooked corn", "主食/蔬菜", 0.55, 0.75, 0.90, "bulk_density", "app heuristic", "medium", "玉米粒/玉米段可食部分"),
    ("sweet_potato_cooked", "红薯/地瓜", "cooked sweet potato", "主食/薯类", 0.70, 0.85, 1.00, "bulk_density", "app heuristic", "medium", "蒸红薯、烤红薯"),
    ("potato_cooked", "土豆/马铃薯", "cooked potato", "薯类", 0.65, 0.80, 0.95, "bulk_density", "app heuristic", "medium", "熟土豆块"),
    ("french_fries", "薯条", "french fries", "油炸小食", 0.35, 0.50, 0.70, "bulk_density", "app heuristic", "medium", "炸薯条"),
    ("potato_wedges", "薯角/土豆块", "potato wedges", "油炸小食", 0.50, 0.65, 0.80, "bulk_density", "app heuristic", "medium", "薯角、炸土豆块"),
    ("fried_potato_ball", "炸丸/土豆球", "fried potato balls", "油炸小食", 0.50, 0.73, 0.90, "bulk_density", "app heuristic", "medium", "圆形炸丸、土豆球"),
    ("fried_chicken", "炸鸡/鸡块/鸡米花", "fried chicken", "油炸肉类", 0.45, 0.65, 0.85, "bulk_density", "app heuristic", "low", "炸鸡块、鸡米花、鸡翅"),
    ("fried_chicken_cutlet", "炸鸡排", "fried chicken cutlet", "油炸肉类", 0.45, 0.62, 0.80, "bulk_density", "app heuristic", "low", "炸鸡排、炸鸡柳"),
    ("fried_cheese_stick", "炸芝士条/长条裹粉小食", "fried cheese stick", "油炸小食", 0.45, 0.65, 0.80, "bulk_density", "app heuristic", "low", "芝士条、长条裹粉小食"),
    ("egg_tart", "蛋挞", "egg tart", "甜品", 0.55, 0.73, 0.90, "bulk_density", "app heuristic", "medium", "葡式蛋挞"),
    ("sausage_cooked", "香肠/烤肠", "cooked sausage", "肉类/加工肉", 0.85, 0.95, 1.05, "bulk_density", "app heuristic", "medium", "香肠、烤肠、热狗肠"),
    ("fried_dough_stick", "油条", "fried dough stick", "油炸主食", 0.15, 0.25, 0.40, "bulk_density", "app heuristic", "low", "油条蓬松体积"),
    ("spring_roll", "春卷", "spring roll", "油炸小食", 0.40, 0.60, 0.80, "bulk_density", "app heuristic", "medium", "炸春卷"),
    ("pork_cooked", "熟猪肉/肉片", "cooked pork", "肉类", 0.65, 0.70, 0.85, "bulk_density", "FAO/INFOODS Density Database V2", "medium", "熟猪肉块、肉片"),
    ("pork_belly_braised", "红烧肉/五花肉", "braised pork belly", "肉类/混合菜", 0.70, 0.85, 1.00, "bulk_density", "app heuristic", "medium", "红烧肉、卤肉块"),
    ("beef_cooked", "熟牛肉", "cooked beef", "肉类", 0.70, 0.85, 1.00, "bulk_density", "app heuristic", "medium", "牛肉块、牛肉片"),
    ("lamb_cooked", "熟羊肉", "cooked lamb", "肉类", 0.70, 0.85, 1.00, "bulk_density", "app heuristic", "medium", "羊肉片、羊肉块"),
    ("chicken_cooked", "熟鸡肉", "cooked chicken", "肉禽", 0.85, 0.95, 1.05, "bulk_density", "app heuristic", "medium", "鸡胸、鸡腿肉、白切鸡"),
    ("duck_cooked", "熟鸭肉", "cooked duck", "肉禽", 0.80, 0.95, 1.05, "bulk_density", "app heuristic", "medium", "鸭肉、烤鸭可食部分"),
    ("fish_cooked", "熟鱼肉", "cooked fish", "鱼虾", 0.75, 0.90, 1.05, "bulk_density", "app heuristic", "medium", "鱼肉可食部分"),
    ("shrimp_cooked", "熟虾仁", "cooked shrimp", "鱼虾", 0.75, 0.90, 1.05, "bulk_density", "app heuristic", "medium", "虾仁、虾肉可食部分"),
    ("egg_boiled", "熟鸡蛋", "boiled egg", "蛋类", 0.55, 0.60, 0.70, "bulk_density", "FAO/INFOODS Density Database V2", "medium", "熟鸡蛋切块/整蛋"),
    ("egg_scrambled", "炒鸡蛋/煎蛋", "scrambled egg / fried egg", "蛋类", 0.55, 0.70, 0.85, "bulk_density", "app heuristic", "medium", "炒蛋、煎蛋"),
    ("tofu_soft", "嫩豆腐/豆腐", "soft tofu", "豆制品", 0.85, 0.95, 1.05, "bulk_density", "app heuristic", "medium", "嫩豆腐、水豆腐"),
    ("tofu_firm", "老豆腐/豆干", "firm tofu", "豆制品", 0.80, 0.95, 1.10, "bulk_density", "app heuristic", "medium", "老豆腐、豆干、香干"),
    ("soy_milk", "豆浆", "soy milk", "饮品", 1.00, 1.03, 1.08, "mass_density", "FAO/INFOODS + app heuristic", "medium", "豆浆"),
    ("milk", "牛奶", "milk", "饮品/奶制品", 1.02, 1.03, 1.04, "mass_density", "FAO/INFOODS Density Database V2", "high", "牛奶"),
    ("yogurt", "酸奶", "yogurt", "奶制品", 1.02, 1.05, 1.10, "mass_density", "FAO/INFOODS + app heuristic", "medium", "普通酸奶"),
    ("tea_unsweetened", "无糖茶/茶水", "unsweetened tea", "饮品", 0.99, 1.00, 1.01, "mass_density", "app_template", "high", "无糖茶、茶水"),
    ("coffee_black", "黑咖啡", "black coffee", "饮品", 0.99, 1.00, 1.01, "mass_density", "FAO/INFOODS Density Database V2", "high", "黑咖啡"),
    ("juice", "果汁", "juice", "饮品", 1.02, 1.05, 1.08, "mass_density", "FAO/INFOODS Density Database V2", "high", "果汁"),
    ("milk_tea_base", "奶茶无料", "milk tea", "饮品", 1.00, 1.03, 1.08, "mass_density", "FAO/INFOODS + app heuristic", "medium", "奶茶液体基底"),
    ("milk_tea_with_toppings", "奶茶有料", "milk tea with toppings", "饮品/甜品", 1.03, 1.08, 1.15, "mass_density", "app heuristic", "medium", "珍珠奶茶、有料奶茶"),
    ("soup_clear", "清汤/汤水", "clear soup", "汤", 1.00, 1.02, 1.05, "mass_density", "app_template", "high", "清汤、茶汤、汤水"),
    ("soup_mixed", "浓汤/混合汤", "mixed soup", "汤", 1.00, 1.05, 1.10, "mass_density", "FAO/INFOODS Density Database V2", "high", "浓汤、混合汤"),
    ("malatang_soup", "麻辣烫汤底", "malatang soup", "汤", 1.00, 1.05, 1.12, "mass_density", "app heuristic", "medium", "麻辣烫汤底"),
    ("hotpot_soup", "火锅汤底", "hotpot soup", "汤", 1.00, 1.05, 1.12, "mass_density", "app heuristic", "medium", "火锅汤底"),
    ("leafy_salad", "生菜/沙拉叶菜", "leafy salad", "蔬菜", 0.12, 0.25, 0.45, "bulk_density", "app heuristic", "low", "生菜、沙拉叶菜"),
    ("stir_fried_vegetables", "炒青菜/熟蔬菜", "stir fried vegetables", "蔬菜", 0.40, 0.55, 0.80, "bulk_density", "FAO/INFOODS + app heuristic", "low", "熟蔬菜、炒青菜"),
    ("cabbage_shredded", "紫甘蓝/包菜丝", "shredded cabbage", "蔬菜", 0.20, 0.35, 0.55, "bulk_density", "app heuristic", "low", "紫甘蓝丝、包菜丝"),
    ("celery_sliced", "芹菜片", "sliced celery", "蔬菜", 0.35, 0.55, 0.75, "bulk_density", "app heuristic", "medium", "芹菜片"),
    ("carrot_sliced", "胡萝卜片", "sliced carrot", "蔬菜", 0.55, 0.75, 0.95, "bulk_density", "app heuristic", "medium", "切片胡萝卜"),
    ("tomato_fresh", "番茄/圣女果", "fresh tomato", "蔬菜/水果", 0.55, 0.75, 0.95, "bulk_density", "app heuristic", "medium", "番茄、圣女果"),
    ("mushroom_fresh", "蘑菇/香菇", "mushroom", "菌菇", 0.30, 0.55, 0.80, "bulk_density", "app heuristic", "medium", "蘑菇、香菇"),
    ("broccoli_cooked", "西兰花", "broccoli", "蔬菜", 0.25, 0.45, 0.70, "bulk_density", "app heuristic", "medium", "西兰花"),
    ("brussels_sprouts", "抱子甘蓝", "brussels sprouts", "蔬菜", 0.55, 0.75, 0.95, "bulk_density", "app heuristic", "medium", "抱子甘蓝"),
    ("leek_sliced", "韭葱/大葱", "leek", "蔬菜", 0.25, 0.45, 0.70, "bulk_density", "app heuristic", "medium", "韭葱、大葱、葱段"),
    ("cucumber", "黄瓜", "cucumber", "蔬菜", 0.45, 0.65, 0.85, "bulk_density", "app heuristic", "medium", "黄瓜片/黄瓜条"),
    ("apple_red", "苹果", "apple", "水果", 0.70, 0.78, 0.90, "bulk_density", "FAO/INFOODS + app heuristic", "medium", "苹果块/苹果片"),
    ("banana", "香蕉", "banana", "水果", 0.75, 0.85, 0.95, "bulk_density", "app heuristic", "medium", "香蕉可食部分"),
    ("fruit_fresh", "新鲜水果", "fresh fruit", "水果", 0.65, 0.80, 0.95, "bulk_density", "FAO/INFOODS + app heuristic", "medium", "切块水果兜底"),
    ("cooking_oil", "食用油", "cooking oil", "油脂", 0.88, 0.92, 0.93, "mass_density", "FAO/INFOODS Density Database V2", "high", "食用油"),
    ("soy_sauce", "酱油", "soy sauce", "酱料", 1.10, 1.12, 1.15, "mass_density", "FAO/INFOODS Density Database V2", "high", "生抽、老抽、酱油"),
    ("salad_dressing", "沙拉酱/油醋汁", "salad dressing", "酱料", 0.95, 1.05, 1.15, "mass_density", "app heuristic", "medium", "沙拉酱、油醋汁、蘸料"),
    ("chili_oil_sauce", "辣椒油/红油", "chili oil sauce", "酱料", 0.90, 0.98, 1.10, "mass_density", "app heuristic", "medium", "辣椒油、红油、蘸料"),
    ("green_pepper_pork_stir_fry", "青椒炒肉", "green pepper pork stir fry", "混合菜", 0.65, 0.75, 0.90, "bulk_density", "app heuristic", "medium", "青椒炒肉、肉片炒菜"),
    ("tomato_egg", "番茄炒蛋", "tomato egg stir fry", "混合菜", 0.65, 0.75, 0.90, "bulk_density", "app heuristic", "medium", "番茄炒蛋"),
    ("mapo_tofu", "麻婆豆腐", "mapo tofu", "混合菜", 0.75, 0.90, 1.05, "bulk_density", "app heuristic", "medium", "麻婆豆腐、豆腐带酱汁"),
    ("braised_dish", "红烧/卤炖菜", "braised dish", "混合菜", 0.70, 0.85, 1.05, "bulk_density", "app heuristic", "medium", "红烧肉、卤味、炖菜整体"),
    ("curry_rice_sauce", "咖喱/盖浇汁", "curry sauce", "混合菜/酱汁", 0.85, 1.00, 1.12, "mass_density", "app heuristic", "medium", "咖喱、盖浇汁"),
    ("rice_meat_veg_bowl", "盖饭/盒饭", "rice bowl", "混合餐", 0.75, 0.83, 0.95, "bulk_density", "FAO/INFOODS + app heuristic", "medium", "米饭+肉菜整体兜底"),
    ("malatang_solid", "麻辣烫固体食材", "malatang solids", "混合菜", 0.55, 0.75, 0.95, "bulk_density", "app heuristic", "medium", "麻辣烫捞出固体"),
    ("hotpot_solid", "火锅固体食材", "hotpot solids", "混合菜", 0.55, 0.75, 0.95, "bulk_density", "app heuristic", "medium", "火锅捞出固体"),
]


ALIASES = [
    ("白米饭", "rice_cooked"), ("米饭", "rice_cooked"), ("熟米饭", "rice_cooked"), ("饭", "rice_cooked"),
    ("紫米饭", "rice_purple"), ("黑米饭", "rice_purple"), ("杂粮饭", "rice_purple"),
    ("炒饭", "rice_fried"), ("蛋炒饭", "rice_fried"), ("扬州炒饭", "rice_fried"), ("辣炒饭", "rice_fried"),
    ("粥", "rice_congee"), ("白粥", "rice_congee"), ("稀饭", "rice_congee"), ("杂粮粥", "rice_congee"),
    ("面条", "noodles_boiled"), ("汤面", "noodles_boiled"), ("熟面条", "noodles_boiled"),
    ("炒面", "noodles_fried"), ("拌面", "noodles_fried"), ("油面", "noodles_fried"),
    ("米粉", "rice_noodles"), ("河粉", "rice_noodles"), ("米线", "rice_noodles"),
    ("馒头", "steamed_bun"), ("花卷", "steamed_bun"), ("包子", "baozi_steamed_bun"),
    ("饺子", "dumpling"), ("水饺", "dumpling"), ("蒸饺", "dumpling"), ("煎饺", "dumpling"),
    ("馄饨", "wonton"), ("云吞", "wonton"),
    ("薯条", "french_fries"), ("炸薯条", "french_fries"),
    ("薯角", "potato_wedges"), ("土豆块", "potato_wedges"),
    ("炸丸", "fried_potato_ball"), ("土豆球", "fried_potato_ball"), ("炸丸子", "fried_potato_ball"),
    ("炸鸡", "fried_chicken"), ("炸鸡块", "fried_chicken"), ("鸡块", "fried_chicken"), ("鸡米花", "fried_chicken"), ("鸡翅", "fried_chicken"),
    ("炸鸡排", "fried_chicken_cutlet"), ("炸鸡柳", "fried_chicken_cutlet"),
    ("芝士条", "fried_cheese_stick"), ("长条裹粉小食", "fried_cheese_stick"),
    ("蛋挞", "egg_tart"), ("香肠", "sausage_cooked"), ("烤肠", "sausage_cooked"),
    ("油条", "fried_dough_stick"), ("春卷", "spring_roll"),
    ("猪肉", "pork_cooked"), ("肉片", "pork_cooked"), ("熟猪肉", "pork_cooked"),
    ("红烧肉", "pork_belly_braised"), ("五花肉", "pork_belly_braised"),
    ("牛肉", "beef_cooked"), ("羊肉", "lamb_cooked"), ("鸡肉", "chicken_cooked"), ("鸡胸肉", "chicken_cooked"), ("鸡腿肉", "chicken_cooked"),
    ("鸭肉", "duck_cooked"), ("鱼肉", "fish_cooked"), ("虾仁", "shrimp_cooked"),
    ("鸡蛋", "egg_boiled"), ("水煮蛋", "egg_boiled"), ("炒鸡蛋", "egg_scrambled"), ("煎蛋", "egg_scrambled"),
    ("豆腐", "tofu_soft"), ("嫩豆腐", "tofu_soft"), ("老豆腐", "tofu_firm"), ("豆干", "tofu_firm"), ("香干", "tofu_firm"),
    ("豆浆", "soy_milk"), ("牛奶", "milk"), ("酸奶", "yogurt"),
    ("茶", "tea_unsweetened"), ("茶水", "tea_unsweetened"), ("无糖茶", "tea_unsweetened"),
    ("黑咖啡", "coffee_black"), ("果汁", "juice"), ("奶茶", "milk_tea_base"), ("珍珠奶茶", "milk_tea_with_toppings"),
    ("清汤", "soup_clear"), ("汤水", "soup_clear"), ("茶汤", "soup_clear"), ("浓汤", "soup_mixed"),
    ("生菜", "leafy_salad"), ("沙拉叶菜", "leafy_salad"), ("青菜", "stir_fried_vegetables"), ("熟蔬菜", "stir_fried_vegetables"),
    ("紫甘蓝", "cabbage_shredded"), ("包菜丝", "cabbage_shredded"), ("芹菜", "celery_sliced"), ("胡萝卜", "carrot_sliced"),
    ("番茄", "tomato_fresh"), ("圣女果", "tomato_fresh"), ("蘑菇", "mushroom_fresh"), ("香菇", "mushroom_fresh"),
    ("西兰花", "broccoli_cooked"), ("抱子甘蓝", "brussels_sprouts"), ("韭葱", "leek_sliced"), ("大葱", "leek_sliced"),
    ("黄瓜", "cucumber"), ("苹果", "apple_red"), ("香蕉", "banana"), ("水果", "fruit_fresh"),
    ("食用油", "cooking_oil"), ("酱油", "soy_sauce"), ("沙拉酱", "salad_dressing"), ("油醋汁", "salad_dressing"), ("蘸料", "salad_dressing"),
    ("青椒炒肉", "green_pepper_pork_stir_fry"), ("番茄炒蛋", "tomato_egg"), ("麻婆豆腐", "mapo_tofu"),
    ("盖饭", "rice_meat_veg_bowl"), ("盒饭", "rice_meat_veg_bowl"), ("便当", "rice_meat_veg_bowl"),
    ("麻辣烫", "malatang_solid"), ("火锅", "hotpot_solid"),
]


def row_from_tuple(values: tuple[str, ...], source_type: str) -> dict[str, str | float]:
    (
        food_key,
        zh_name,
        en_name,
        category,
        density_min,
        density_default,
        density_max,
        density_type,
        source,
        source_confidence,
        notes,
    ) = values
    return {
        "food_key": food_key,
        "zh_name": zh_name,
        "en_name": en_name,
        "category": category,
        "density_min": density_min,
        "density_default": density_default,
        "density_max": density_max,
        "density_type": density_type,
        "source": source,
        "source_confidence": source_confidence,
        "source_type": source_type,
        "notes": notes,
    }


def category_row_from_tuple(values: tuple[str, ...]) -> dict[str, str | float]:
    (
        food_key,
        zh_name,
        density_min,
        density_default,
        density_max,
        density_type,
        source,
        source_confidence,
        notes,
    ) = values
    return {
        "food_key": "category_" + food_key,
        "zh_name": zh_name,
        "en_name": food_key,
        "category": "大类兜底",
        "density_min": density_min,
        "density_default": density_default,
        "density_max": density_max,
        "density_type": density_type,
        "source": source,
        "source_confidence": source_confidence,
        "source_type": "category_default",
        "notes": notes,
    }


def read_fao_rows() -> list[dict[str, str | float]]:
    rows: list[dict[str, str | float]] = []
    with FAO_APP_READY.open(encoding="utf-8") as handle:
        for source_row in csv.DictReader(handle):
            density = source_row.get("density_default_g_per_ml") or ""
            if not density:
                continue
            value = float(density)
            rows.append(
                {
                    "food_key": "fao_" + source_row["food_key"],
                    "zh_name": "",
                    "en_name": source_row["food_name_en"],
                    "category": source_row["food_group"],
                    "density_min": round(max(0.01, value * 0.95), 4),
                    "density_default": round(value, 4),
                    "density_max": round(value * 1.05, 4),
                    "density_type": "mass_or_bulk_density",
                    "source": source_row["source"],
                    "source_confidence": "high" if source_row.get("density_source_column") == "density_g_per_ml" else "medium",
                    "source_type": "fao_infoods_v2",
                    "notes": f"biblio_id={source_row.get('biblio_id','')}; source_row={source_row.get('source_row','')}",
                }
            )
    return rows


def write_csv(path: Path, rows: list[dict], fieldnames: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def write_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")


def import_sqlite(unified_rows: list[dict], alias_rows: list[dict]) -> None:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS food_density (
                food_key TEXT PRIMARY KEY,
                zh_name TEXT DEFAULT '',
                en_name TEXT DEFAULT '',
                category TEXT DEFAULT '',
                density_min REAL,
                density_default REAL NOT NULL,
                density_max REAL,
                density_type TEXT DEFAULT '',
                source TEXT DEFAULT '',
                source_confidence TEXT DEFAULT '',
                source_type TEXT DEFAULT '',
                notes TEXT DEFAULT '',
                updated_at TEXT DEFAULT CURRENT_TIMESTAMP
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS food_density_aliases (
                alias_zh TEXT PRIMARY KEY,
                food_key TEXT NOT NULL,
                priority INTEGER DEFAULT 100,
                notes TEXT DEFAULT ''
            )
            """
        )
        conn.executemany(
            """
            INSERT OR REPLACE INTO food_density
            (food_key, zh_name, en_name, category, density_min, density_default, density_max,
             density_type, source, source_confidence, source_type, notes, updated_at)
            VALUES (:food_key, :zh_name, :en_name, :category, :density_min, :density_default, :density_max,
                    :density_type, :source, :source_confidence, :source_type, :notes, CURRENT_TIMESTAMP)
            """,
            unified_rows,
        )
        conn.executemany(
            """
            INSERT OR REPLACE INTO food_density_aliases
            (alias_zh, food_key, priority, notes)
            VALUES (:alias_zh, :food_key, :priority, :notes)
            """,
            alias_rows,
        )


def main() -> None:
    if not FAO_APP_READY.exists():
        raise SystemExit(f"Missing FAO app-ready CSV: {FAO_APP_READY}")

    fao_rows = read_fao_rows()
    category_rows = [category_row_from_tuple(row) for row in CATEGORY_DEFAULTS]
    high_frequency_rows = [row_from_tuple(row, "chinese_high_frequency") for row in CHINESE_HIGH_FREQUENCY]

    by_key: dict[str, dict] = {}
    for row in fao_rows:
        by_key[str(row["food_key"])] = row
    for row in category_rows + high_frequency_rows:
        by_key[str(row["food_key"])] = row
    unified_rows = sorted(by_key.values(), key=lambda row: (str(row["source_type"]), str(row["food_key"])))

    alias_rows = [
        {"alias_zh": alias, "food_key": food_key, "priority": 10, "notes": "manual Chinese alias"}
        for alias, food_key in ALIASES
    ]

    fields = [
        "food_key",
        "zh_name",
        "en_name",
        "category",
        "density_min",
        "density_default",
        "density_max",
        "density_type",
        "source",
        "source_confidence",
        "source_type",
        "notes",
    ]
    write_csv(OUT_DIR / "food_density_unified.csv", unified_rows, fields)
    write_jsonl(OUT_DIR / "food_density_unified.jsonl", unified_rows)
    write_csv(OUT_DIR / "food_density_category_defaults.csv", category_rows, fields)
    write_csv(OUT_DIR / "food_density_chinese_high_frequency.csv", high_frequency_rows, fields)
    write_csv(OUT_DIR / "food_density_aliases_zh.csv", alias_rows, ["alias_zh", "food_key", "priority", "notes"])
    import_sqlite(unified_rows, alias_rows)

    summary = {
        "fao_rows": len(fao_rows),
        "category_defaults": len(category_rows),
        "chinese_high_frequency": len(high_frequency_rows),
        "aliases_zh": len(alias_rows),
        "unified_rows": len(unified_rows),
        "sqlite_db": str(DB_PATH),
        "output_dir": str(OUT_DIR),
    }
    (OUT_DIR / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
