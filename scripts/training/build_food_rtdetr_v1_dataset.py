#!/usr/bin/env python3
"""Build the Food RT-DETR v1 COCO dataset scaffold.

The builder accepts a normalized JSONL stream where every row already points to
an image and a bbox. Source-specific converters can feed this format, while the
COCO writer keeps product metadata needed for license and pseudo-label audits.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import random
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

from PIL import Image

IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}
CLASSIFICATION_SPLIT_MAP = {
    "train": "train",
    "training": "train",
    "val": "val",
    "valid": "val",
    "validation": "val",
    "test": "val",
    "testing": "val",
}


@dataclass(frozen=True)
class FoodClass:
    canonical_label: str
    fallback_label: str
    tier: str
    group: str
    aliases: tuple[str, ...] = ()


@dataclass(frozen=True)
class SourcePolicy:
    source_dataset: str
    dataset_type: str
    license_risk: str
    bbox_type: str
    product_use: str
    note: str


@dataclass(frozen=True)
class LabelMapping:
    original_label: str
    canonical_label: str
    fallback_label: str
    tier: str
    group: str


@dataclass(frozen=True)
class BboxQuality:
    keep: bool
    score: float
    reasons: list[str]


FOOD_CLASSES: tuple[FoodClass, ...] = (
    FoodClass("黄焖鸡米饭", "鸡肉盖饭", "dish", "rice_bowl", ("braised chicken rice", "huangmen chicken rice")),
    FoodClass("鸡肉盖饭", "盖浇饭", "dish", "rice_bowl", ("chicken rice bowl", "chicken over rice", "teriyaki chicken rice")),
    FoodClass("牛肉盖饭", "盖浇饭", "dish", "rice_bowl", ("beef rice bowl", "gyudon")),
    FoodClass("猪肉盖饭", "盖浇饭", "dish", "rice_bowl", ("pork rice bowl",)),
    FoodClass("鱼香肉丝盖饭", "盖浇饭", "dish", "rice_bowl", ("yuxiang shredded pork rice",)),
    FoodClass("宫保鸡丁盖饭", "鸡肉盖饭", "dish", "rice_bowl", ("kung pao chicken rice",)),
    FoodClass("番茄炒蛋盖饭", "盖浇饭", "dish", "rice_bowl", ("tomato egg rice", "tomato and egg rice")),
    FoodClass("土豆牛肉盖饭", "牛肉盖饭", "dish", "rice_bowl", ("beef potato rice",)),
    FoodClass("咖喱鸡饭", "咖喱饭", "dish", "rice_bowl", ("chicken curry rice",)),
    FoodClass("咖喱牛肉饭", "咖喱饭", "dish", "rice_bowl", ("beef curry rice",)),
    FoodClass("咖喱饭", "盖浇饭", "dish", "rice_bowl", ("curry rice",)),
    FoodClass("卤肉饭", "盖浇饭", "dish", "rice_bowl", ("braised pork rice", "lu rou fan")),
    FoodClass("叉烧饭", "盖浇饭", "dish", "rice_bowl", ("char siu rice",)),
    FoodClass("烧鸭饭", "盖浇饭", "dish", "rice_bowl", ("roast duck rice",)),
    FoodClass("烧鹅饭", "盖浇饭", "dish", "rice_bowl", ("roast goose rice",)),
    FoodClass("鸡排饭", "鸡肉盖饭", "dish", "rice_bowl", ("chicken cutlet rice",)),
    FoodClass("猪排饭", "猪肉盖饭", "dish", "rice_bowl", ("pork cutlet rice", "tonkatsu rice")),
    FoodClass("照烧鸡饭", "鸡肉盖饭", "dish", "rice_bowl", ("teriyaki chicken rice",)),
    FoodClass("肥牛饭", "牛肉盖饭", "dish", "rice_bowl", ("fatty beef rice",)),
    FoodClass("石锅拌饭", "韩式拌饭", "dish", "rice_bowl", ("bibimbap", "stone pot bibimbap")),
    FoodClass("韩式拌饭", "盖浇饭", "dish", "rice_bowl", ("korean mixed rice",)),
    FoodClass("日式便当", "便当", "dish", "rice_bowl", ("japanese bento", "bento")),
    FoodClass("中式盒饭", "便当", "dish", "rice_bowl", ("chinese boxed meal", "boxed lunch")),
    FoodClass("食堂餐盘", "套餐", "dish", "rice_bowl", ("cafeteria tray", "cafeteria meal")),
    FoodClass("双拼饭", "盖浇饭", "dish", "rice_bowl", ("two topping rice",)),
    FoodClass("炒饭", "主食", "dish", "rice_bowl", ("fried rice",)),
    FoodClass("蛋炒饭", "炒饭", "dish", "rice_bowl", ("egg fried rice",)),
    FoodClass("扬州炒饭", "炒饭", "dish", "rice_bowl", ("yangzhou fried rice", "yang chow fried rice")),
    FoodClass("腊肠炒饭", "炒饭", "dish", "rice_bowl", ("sausage fried rice",)),
    FoodClass("海鲜炒饭", "炒饭", "dish", "rice_bowl", ("seafood fried rice",)),
    FoodClass("盖浇饭", "主食", "fallback", "rice_bowl", ("rice bowl", "donburi")),
    FoodClass("米饭", "主食", "fallback", "rice_bowl", ("rice", "steamed rice", "white rice")),
    FoodClass("兰州拉面", "牛肉面", "dish", "noodles", ("lanzhou beef noodles", "lanzhou ramen")),
    FoodClass("牛肉面", "面条", "dish", "noodles", ("beef noodle soup", "beef noodles")),
    FoodClass("重庆小面", "面条", "dish", "noodles", ("chongqing noodles",)),
    FoodClass("热干面", "面条", "dish", "noodles", ("hot dry noodles",)),
    FoodClass("炸酱面", "面条", "dish", "noodles", ("zhajiangmian", "noodles with soybean paste")),
    FoodClass("拌面", "面条", "dish", "noodles", ("mixed noodles",)),
    FoodClass("炒面", "面条", "dish", "noodles", ("fried noodles", "chow mein")),
    FoodClass("意大利面", "面条", "dish", "noodles", ("pasta", "spaghetti")),
    FoodClass("日式拉面", "面条", "dish", "noodles", ("ramen", "japanese ramen")),
    FoodClass("乌冬面", "面条", "dish", "noodles", ("udon",)),
    FoodClass("冷面", "面条", "dish", "noodles", ("cold noodles",)),
    FoodClass("螺蛳粉", "米粉汤", "dish", "noodles", ("luosifen", "river snail rice noodles")),
    FoodClass("桂林米粉", "米粉汤", "dish", "noodles", ("guilin rice noodles",)),
    FoodClass("过桥米线", "米粉汤", "dish", "noodles", ("crossing bridge rice noodles",)),
    FoodClass("酸辣粉", "米粉汤", "dish", "noodles", ("hot and sour noodles",)),
    FoodClass("河粉", "面条", "dish", "noodles", ("rice noodles", "rice noodle")),
    FoodClass("炒河粉", "河粉", "dish", "noodles", ("fried rice noodles",)),
    FoodClass("米粉汤", "面条", "fallback", "noodles", ("rice noodle soup",)),
    FoodClass("刀削面", "面条", "dish", "noodles", ("knife cut noodles",)),
    FoodClass("臊子面", "面条", "dish", "noodles", ("saozi noodles",)),
    FoodClass("担担面", "面条", "dish", "noodles", ("dan dan noodles",)),
    FoodClass("面条", "主食", "fallback", "noodles", ("noodles", "noodle")),
    FoodClass("麻辣烫", "汤类", "dish", "hotpot", ("malatang",)),
    FoodClass("麻辣香锅", "肉类菜", "dish", "hotpot", ("spicy dry pot", "mala xiang guo")),
    FoodClass("冒菜", "汤类", "dish", "hotpot", ("maocai",)),
    FoodClass("火锅", "汤类", "dish", "hotpot", ("hot pot", "hotpot")),
    FoodClass("酸菜鱼", "鱼类菜", "dish", "hotpot", ("sauerkraut fish", "pickled cabbage fish")),
    FoodClass("水煮鱼", "鱼类菜", "dish", "hotpot", ("boiled fish in chili oil",)),
    FoodClass("水煮肉片", "肉类菜", "dish", "hotpot", ("boiled pork slices",)),
    FoodClass("毛血旺", "肉类菜", "dish", "hotpot", ("maoxuewang",)),
    FoodClass("关东煮", "汤类", "dish", "hotpot", ("oden",)),
    FoodClass("砂锅粉", "米粉汤", "dish", "hotpot", ("clay pot rice noodles",)),
    FoodClass("砂锅饭", "盖浇饭", "dish", "hotpot", ("clay pot rice",)),
    FoodClass("炖汤", "汤类", "fallback", "soup", ("stew soup",)),
    FoodClass("鸡汤", "汤类", "dish", "soup", ("chicken soup",)),
    FoodClass("排骨汤", "汤类", "dish", "soup", ("pork rib soup",)),
    FoodClass("牛肉汤", "汤类", "dish", "soup", ("beef soup",)),
    FoodClass("羊肉汤", "汤类", "dish", "soup", ("mutton soup", "lamb soup")),
    FoodClass("汤", "汤类", "fallback", "soup", ("soup",)),
    FoodClass("白粥", "主食", "dish", "breakfast", ("plain congee", "congee")),
    FoodClass("皮蛋瘦肉粥", "白粥", "dish", "breakfast", ("century egg pork congee",)),
    FoodClass("小米粥", "白粥", "dish", "breakfast", ("millet porridge",)),
    FoodClass("豆浆", "饮品", "dish", "breakfast", ("soy milk", "soymilk")),
    FoodClass("油条", "主食", "dish", "breakfast", ("youtiao", "fried dough stick")),
    FoodClass("包子", "主食", "dish", "breakfast", ("baozi", "steamed bun")),
    FoodClass("馒头", "主食", "dish", "breakfast", ("mantou", "steamed bread")),
    FoodClass("花卷", "主食", "dish", "breakfast", ("hanamaki", "steamed twisted roll")),
    FoodClass("煎饼果子", "主食", "dish", "breakfast", ("jianbing", "chinese crepe")),
    FoodClass("手抓饼", "主食", "dish", "breakfast", ("scallion pancake wrap",)),
    FoodClass("鸡蛋灌饼", "主食", "dish", "breakfast", ("egg stuffed pancake",)),
    FoodClass("烧饼", "主食", "dish", "breakfast", ("shaobing", "sesame flatbread")),
    FoodClass("饺子", "主食", "dish", "breakfast", ("dumplings", "dumpling")),
    FoodClass("煎饺", "饺子", "dish", "breakfast", ("pan fried dumplings", "potstickers")),
    FoodClass("蒸饺", "饺子", "dish", "breakfast", ("steamed dumplings",)),
    FoodClass("馄饨", "主食", "dish", "breakfast", ("wonton", "wontons")),
    FoodClass("云吞", "馄饨", "dish", "breakfast", ("wonton soup",)),
    FoodClass("小笼包", "包子", "dish", "breakfast", ("xiaolongbao", "soup dumplings")),
    FoodClass("烧麦", "主食", "dish", "breakfast", ("shaomai", "shumai")),
    FoodClass("饭团", "主食", "dish", "breakfast", ("rice ball", "onigiri")),
    FoodClass("三明治", "主食", "dish", "breakfast", ("sandwich",)),
    FoodClass("吐司", "主食", "dish", "breakfast", ("toast",)),
    FoodClass("汉堡早餐", "汉堡", "dish", "breakfast", ("breakfast burger",)),
    FoodClass("炸鸡", "肉类菜", "dish", "fast_food", ("fried chicken",)),
    FoodClass("鸡翅", "肉类菜", "dish", "fast_food", ("chicken wings", "chicken wing")),
    FoodClass("鸡腿", "肉类菜", "dish", "fast_food", ("chicken leg", "drumstick")),
    FoodClass("鸡排", "肉类菜", "dish", "fast_food", ("chicken cutlet",)),
    FoodClass("薯条", "主食", "dish", "fast_food", ("french fries", "fries")),
    FoodClass("汉堡", "主食", "dish", "fast_food", ("hamburger", "burger", "hamburg")),
    FoodClass("披萨", "主食", "dish", "fast_food", ("pizza",)),
    FoodClass("热狗", "主食", "dish", "fast_food", ("hot dog", "hotdog")),
    FoodClass("炸串", "肉类菜", "dish", "fast_food", ("fried skewers",)),
    FoodClass("烧烤", "肉类菜", "dish", "fast_food", ("barbecue", "bbq skewers")),
    FoodClass("烤肉饭", "盖浇饭", "dish", "fast_food", ("bbq rice", "grilled meat rice")),
    FoodClass("烤鸡", "肉类菜", "dish", "fast_food", ("roast chicken", "grilled chicken")),
    FoodClass("烤鱼", "鱼类菜", "dish", "fast_food", ("grilled fish",)),
    FoodClass("烤肠", "肉类菜", "dish", "fast_food", ("grilled sausage", "sausage")),
    FoodClass("炸猪排", "肉类菜", "dish", "fast_food", ("fried pork cutlet", "tonkatsu")),
    FoodClass("炸虾", "肉类菜", "dish", "fast_food", ("fried shrimp",)),
    FoodClass("炸鱼", "鱼类菜", "dish", "fast_food", ("fried fish",)),
    FoodClass("炸物拼盘", "套餐", "dish", "fast_food", ("fried platter",)),
    FoodClass("蔬菜沙拉", "蔬菜菜", "dish", "light_food", ("vegetable salad", "salad")),
    FoodClass("鸡胸肉沙拉", "蔬菜沙拉", "dish", "light_food", ("chicken breast salad", "chicken salad")),
    FoodClass("牛肉沙拉", "蔬菜沙拉", "dish", "light_food", ("beef salad",)),
    FoodClass("三文鱼沙拉", "蔬菜沙拉", "dish", "light_food", ("salmon salad",)),
    FoodClass("轻食碗", "蔬菜沙拉", "dish", "light_food", ("grain bowl", "healthy bowl", "light meal bowl")),
    FoodClass("藜麦碗", "轻食碗", "dish", "light_food", ("quinoa bowl",)),
    FoodClass("鸡胸肉餐", "鸡肉盖饭", "dish", "light_food", ("chicken breast meal",)),
    FoodClass("健身餐", "轻食碗", "fallback", "light_food", ("fitness meal",)),
    FoodClass("低脂便当", "便当", "fallback", "light_food", ("low fat bento",)),
    FoodClass("水果碗", "水果拼盘", "dish", "light_food", ("fruit bowl",)),
    FoodClass("酸奶碗", "甜品", "dish", "light_food", ("yogurt bowl",)),
    FoodClass("燕麦碗", "主食", "dish", "light_food", ("oatmeal bowl", "oatmeal")),
    FoodClass("蛋糕", "甜品", "dish", "dessert", ("cake",)),
    FoodClass("面包", "主食", "dish", "dessert", ("bread",)),
    FoodClass("蛋挞", "甜品", "dish", "dessert", ("egg tart",)),
    FoodClass("甜甜圈", "甜品", "dish", "dessert", ("donut", "doughnut")),
    FoodClass("饼干", "甜品", "dish", "dessert", ("biscuit", "cookie")),
    FoodClass("冰淇淋", "甜品", "dish", "dessert", ("ice cream",)),
    FoodClass("布丁", "甜品", "dish", "dessert", ("pudding",)),
    FoodClass("奶酪", "甜品", "dish", "dessert", ("cheese", "cheese butter")),
    FoodClass("巧克力", "甜品", "dish", "dessert", ("chocolate",)),
    FoodClass("水果拼盘", "甜品", "dish", "dessert", ("fruit platter",)),
    FoodClass("西瓜", "水果拼盘", "dish", "dessert", ("watermelon",)),
    FoodClass("香蕉", "水果拼盘", "dish", "dessert", ("banana",)),
    FoodClass("苹果", "水果拼盘", "dish", "dessert", ("apple",)),
    FoodClass("草莓", "水果拼盘", "dish", "dessert", ("strawberry",)),
    FoodClass("葡萄", "水果拼盘", "dish", "dessert", ("grape",)),
    FoodClass("甜品", "未知西餐", "fallback", "dessert", ("dessert",)),
    FoodClass("奶茶", "饮料", "dish", "drink", ("milk tea",)),
    FoodClass("珍珠奶茶", "奶茶", "dish", "drink", ("bubble tea", "boba tea")),
    FoodClass("果茶", "饮料", "dish", "drink", ("fruit tea",)),
    FoodClass("咖啡", "饮料", "dish", "drink", ("coffee",)),
    FoodClass("拿铁", "咖啡", "dish", "drink", ("latte",)),
    FoodClass("美式咖啡", "咖啡", "dish", "drink", ("americano", "black coffee")),
    FoodClass("奶昔", "饮料", "dish", "drink", ("milkshake",)),
    FoodClass("可乐", "饮料", "dish", "drink", ("cola", "coke")),
    FoodClass("汽水", "饮料", "dish", "drink", ("soda", "soft drink")),
    FoodClass("果汁", "饮料", "dish", "drink", ("juice",)),
    FoodClass("酸奶", "饮料", "dish", "drink", ("yogurt",)),
    FoodClass("饮料", "未知饮品", "fallback", "drink", ("drink", "beverage")),
    FoodClass("套餐", "未知中餐", "fallback", "generic", ("combo meal", "set meal")),
    FoodClass("便当", "套餐", "fallback", "generic", ("bento box",)),
    FoodClass("肉类菜", "未知中餐", "fallback", "generic", ("meat dish", "protein")),
    FoodClass("鱼类菜", "肉类菜", "fallback", "generic", ("fish dish",)),
    FoodClass("蔬菜菜", "未知中餐", "fallback", "generic", ("vegetable dish", "vegetables")),
    FoodClass("主食", "未知中餐", "fallback", "generic", ("staple food",)),
    FoodClass("汤类", "未知中餐", "fallback", "generic", ("soup dish",)),
    FoodClass("未知中餐", "未知中餐", "fallback", "unknown", ("unknown chinese food",)),
    FoodClass("未知西餐", "未知西餐", "fallback", "unknown", ("unknown western food", "food")),
    FoodClass("未知饮品", "未知饮品", "fallback", "unknown", ("unknown drink",)),
)


SOURCE_POLICIES: tuple[SourcePolicy, ...] = (
    SourcePolicy("UECFOOD-100", "bbox", "needs_license_review", "real_bbox", "research_and_candidate", "Official bbox dataset; verify original terms before commercial launch."),
    SourcePolicy("UECFOOD-256", "bbox", "needs_license_review", "real_bbox", "research_and_candidate", "Official bbox dataset; verify original terms before commercial launch."),
    SourcePolicy("Roboflow-UECFOOD256-CCBY4", "bbox", "cc_by_4_0", "real_bbox", "commercial_candidate_with_attribution", "Third-party conversion; keep attribution and original-source review."),
    SourcePolicy("FoodSeg103", "mask", "apache_2_0", "mask_to_bbox", "commercial_candidate", "Ingredient segmentation data; convert masks to ingredient/fallback boxes."),
    SourcePolicy("FoodSeg154", "mask", "apache_2_0", "mask_to_bbox", "commercial_candidate", "Extended segmentation data where available."),
    SourcePolicy("UECFoodPixComplete", "mask", "needs_license_review", "mask_to_bbox", "research_and_candidate", "Pixel-level food masks; verify terms before commercial launch."),
    SourcePolicy("ChineseFoodNet", "classification", "research_only", "pseudo_sam2", "research_only", "Academic-research dataset; do not include in commercial export without permission."),
    SourcePolicy("VireoFood-172", "classification", "needs_license_review", "pseudo_sam2", "research_and_candidate", "Classification/ingredient metadata; verify terms."),
    SourcePolicy("Food2K", "classification", "needs_license_review", "pseudo_sam2", "research_and_candidate", "Large classification pool; sample by class and disk budget."),
    SourcePolicy("ISIA Food-500", "classification", "needs_license_review", "pseudo_sam2", "research_and_candidate", "Large classification pool; verify terms."),
    SourcePolicy("FoodX-251", "classification", "research_only", "pseudo_sam2", "research_only", "iFood/FoodX data terms are non-commercial research and educational use."),
    SourcePolicy("Food-101", "classification", "research_only", "pseudo_sam2", "research_only", "Foodspotting-derived images; avoid commercial export unless rights are cleared."),
    SourcePolicy("Nutrition5k", "eval", "needs_license_review", "eval_only", "evaluation_only", "Nutrition/depth evaluation data; not primary detector training."),
    SourcePolicy("SelfCollected", "bbox", "owned_or_user_authorized", "manual_bbox", "commercial_candidate", "Product data with explicit user or internal authorization."),
)


SOURCE_POLICY_BY_NAME = {policy.source_dataset.casefold(): policy for policy in SOURCE_POLICIES}
FOOD_CLASS_BY_LABEL = {food.canonical_label: food for food in FOOD_CLASSES}
ALIAS_TO_CLASS: dict[str, FoodClass] = {}
for food_class in FOOD_CLASSES:
    ALIAS_TO_CLASS[food_class.canonical_label.casefold()] = food_class
    for alias in food_class.aliases:
        ALIAS_TO_CLASS[alias.casefold()] = food_class

ADDITIONAL_LABEL_ALIASES = {
    "candy": "甜品",
    "popcorn": "甜品",
    "wine": "饮料",
    "milk": "饮料",
    "almond": "主食",
    "red beans": "主食",
    "cashew": "主食",
    "dried cranberries": "水果拼盘",
    "soy": "主食",
    "walnut": "主食",
    "peanut": "主食",
    "egg": "主食",
    "date": "水果拼盘",
    "apricot": "水果拼盘",
    "avocado": "水果拼盘",
    "cherry": "水果拼盘",
    "blueberry": "水果拼盘",
    "raspberry": "水果拼盘",
    "mango": "水果拼盘",
    "olives": "蔬菜菜",
    "peach": "水果拼盘",
    "lemon": "水果拼盘",
    "pear": "水果拼盘",
    "fig": "水果拼盘",
    "pineapple": "水果拼盘",
    "kiwi": "水果拼盘",
    "melon": "水果拼盘",
    "orange": "水果拼盘",
    "steak": "肉类菜",
    "pork": "肉类菜",
    "chicken duck": "肉类菜",
    "sausage": "肉类菜",
    "fried meat": "肉类菜",
    "lamb": "肉类菜",
    "sauce": "未知中餐",
    "crab": "鱼类菜",
    "fish": "鱼类菜",
    "shellfish": "鱼类菜",
    "shrimp": "鱼类菜",
    "corn": "主食",
    "hanamaki baozi": "包子",
    "wonton dumplings": "饺子",
    "tofu": "蔬菜菜",
    "eggplant": "蔬菜菜",
    "potato": "蔬菜菜",
    "garlic": "蔬菜菜",
    "cauliflower": "蔬菜菜",
    "tomato": "蔬菜菜",
    "kelp": "蔬菜菜",
    "seaweed": "蔬菜菜",
    "spring onion": "蔬菜菜",
    "rape": "蔬菜菜",
    "ginger": "蔬菜菜",
    "okra": "蔬菜菜",
    "lettuce": "蔬菜菜",
    "pumpkin": "蔬菜菜",
    "cucumber": "蔬菜菜",
    "white radish": "蔬菜菜",
    "carrot": "蔬菜菜",
    "asparagus": "蔬菜菜",
    "bamboo shoots": "蔬菜菜",
    "broccoli": "蔬菜菜",
    "celery stick": "蔬菜菜",
    "cilantro mint": "蔬菜菜",
    "snow peas": "蔬菜菜",
    "cabbage": "蔬菜菜",
    "bean sprouts": "蔬菜菜",
    "onion": "蔬菜菜",
    "pepper": "蔬菜菜",
    "green beans": "蔬菜菜",
    "french beans": "蔬菜菜",
    "king oyster mushroom": "蔬菜菜",
    "shiitake": "蔬菜菜",
    "enoki mushroom": "蔬菜菜",
    "oyster mushroom": "蔬菜菜",
    "white button mushroom": "蔬菜菜",
    "other ingredients": "未知西餐",
}
for alias, canonical_label in ADDITIONAL_LABEL_ALIASES.items():
    food_class = FOOD_CLASS_BY_LABEL.get(canonical_label)
    if food_class is not None:
        ALIAS_TO_CLASS[alias.casefold()] = food_class

FOODSEG103_LABELS: dict[int, str] = {
    0: "background",
    1: "candy",
    2: "egg tart",
    3: "french fries",
    4: "chocolate",
    5: "biscuit",
    6: "popcorn",
    7: "pudding",
    8: "ice cream",
    9: "cheese butter",
    10: "cake",
    11: "wine",
    12: "milkshake",
    13: "coffee",
    14: "juice",
    15: "milk",
    16: "tea",
    17: "almond",
    18: "red beans",
    19: "cashew",
    20: "dried cranberries",
    21: "soy",
    22: "walnut",
    23: "peanut",
    24: "egg",
    25: "apple",
    26: "date",
    27: "apricot",
    28: "avocado",
    29: "banana",
    30: "strawberry",
    31: "cherry",
    32: "blueberry",
    33: "raspberry",
    34: "mango",
    35: "olives",
    36: "peach",
    37: "lemon",
    38: "pear",
    39: "fig",
    40: "pineapple",
    41: "grape",
    42: "kiwi",
    43: "melon",
    44: "orange",
    45: "watermelon",
    46: "steak",
    47: "pork",
    48: "chicken duck",
    49: "sausage",
    50: "fried meat",
    51: "lamb",
    52: "sauce",
    53: "crab",
    54: "fish",
    55: "shellfish",
    56: "shrimp",
    57: "soup",
    58: "bread",
    59: "corn",
    60: "hamburg",
    61: "pizza",
    62: "hanamaki baozi",
    63: "wonton dumplings",
    64: "pasta",
    65: "noodles",
    66: "rice",
    67: "pie",
    68: "tofu",
    69: "eggplant",
    70: "potato",
    71: "garlic",
    72: "cauliflower",
    73: "tomato",
    74: "kelp",
    75: "seaweed",
    76: "spring onion",
    77: "rape",
    78: "ginger",
    79: "okra",
    80: "lettuce",
    81: "pumpkin",
    82: "cucumber",
    83: "white radish",
    84: "carrot",
    85: "asparagus",
    86: "bamboo shoots",
    87: "broccoli",
    88: "celery stick",
    89: "cilantro mint",
    90: "snow peas",
    91: "cabbage",
    92: "bean sprouts",
    93: "onion",
    94: "pepper",
    95: "green beans",
    96: "French beans",
    97: "king oyster mushroom",
    98: "shiitake",
    99: "enoki mushroom",
    100: "oyster mushroom",
    101: "white button mushroom",
    102: "salad",
    103: "other ingredients",
}


def normalize_label(value: str) -> str:
    return " ".join(str(value or "").replace("_", " ").replace("-", " ").strip().casefold().split())


def display_label(value: str) -> str:
    return " ".join(str(value or "").replace("_", " ").replace("-", " ").strip().split())


def map_label(original_label: str) -> LabelMapping:
    key = normalize_label(original_label)
    food_class = ALIAS_TO_CLASS.get(key)
    if food_class is None:
        if any(token in key for token in ("tea", "coffee", "juice", "milk", "drink", "cola", "soda")):
            food_class = FOOD_CLASS_BY_LABEL["未知饮品"]
        elif any("\u4e00" <= ch <= "\u9fff" for ch in str(original_label)):
            food_class = FOOD_CLASS_BY_LABEL["未知中餐"]
        else:
            food_class = FOOD_CLASS_BY_LABEL["未知西餐"]
    return LabelMapping(
        original_label=str(original_label or ""),
        canonical_label=food_class.canonical_label,
        fallback_label=food_class.fallback_label,
        tier=food_class.tier,
        group=food_class.group,
    )


def get_source_policy(source_dataset: str, bbox_type: str | None = None) -> SourcePolicy:
    policy = SOURCE_POLICY_BY_NAME.get(str(source_dataset or "").casefold())
    if policy is not None:
        return policy
    inferred_bbox_type = bbox_type or "unknown"
    return SourcePolicy(
        source_dataset=source_dataset or "Unknown",
        dataset_type="unknown",
        license_risk="needs_license_review",
        bbox_type=inferred_bbox_type,
        product_use="research_and_candidate",
        note="Unregistered source; review before using in commercial export.",
    )


def xyxy_to_xywh(bbox_xyxy: Iterable[float]) -> list[float]:
    x1, y1, x2, y2 = [float(v) for v in bbox_xyxy]
    return [x1, y1, max(0.0, x2 - x1), max(0.0, y2 - y1)]


def normalize_bbox(bbox: Iterable[float], bbox_format: str) -> list[float]:
    values = [float(v) for v in bbox]
    if bbox_format == "xyxy":
        return xyxy_to_xywh(values)
    if bbox_format == "xywh":
        x, y, w, h = values
        return [x, y, max(0.0, w), max(0.0, h)]
    raise ValueError(f"unsupported bbox_format: {bbox_format}")


def xywh_to_xyxy(bbox_xywh: Iterable[float]) -> list[float]:
    x, y, w, h = [float(v) for v in bbox_xywh]
    return [x, y, x + w, y + h]


def score_bbox_quality(
    image_width: int,
    image_height: int,
    bbox_xyxy: Iterable[float],
    bbox_type: str,
    mask_area: int | float | None = None,
    predicted_iou: float | None = None,
    stability_score: float | None = None,
) -> BboxQuality:
    x1, y1, x2, y2 = [float(v) for v in bbox_xyxy]
    width = max(0.0, x2 - x1)
    height = max(0.0, y2 - y1)
    image_area = max(1.0, float(image_width * image_height))
    bbox_area = width * height
    area_ratio = bbox_area / image_area
    reasons: list[str] = []

    if width <= 1 or height <= 1:
        reasons.append("empty_bbox")
    if area_ratio < 0.15 or area_ratio > 0.95:
        reasons.append("area_ratio_out_of_range")
    touches_left = x1 <= 1
    touches_top = y1 <= 1
    touches_right = x2 >= image_width - 1
    touches_bottom = y2 >= image_height - 1
    if area_ratio > 0.85 and touches_left and touches_top and touches_right and touches_bottom:
        reasons.append("touches_full_image")

    center_x = (x1 + x2) / 2.0 / max(float(image_width), 1.0)
    center_y = (y1 + y2) / 2.0 / max(float(image_height), 1.0)
    center_distance = abs(center_x - 0.5) + abs(center_y - 0.5)
    score = 1.0

    if bbox_type.startswith("pseudo"):
        if mask_area is not None:
            mask_ratio = float(mask_area) / image_area
            if mask_ratio < 0.08 and "area_ratio_out_of_range" not in reasons:
                reasons.append("mask_too_small")
                score -= 0.25
            if mask_ratio > 0.95 and "area_ratio_out_of_range" not in reasons:
                reasons.append("mask_too_large")
                score -= 0.25
        if predicted_iou is not None:
            score *= max(0.0, min(float(predicted_iou), 1.0))
        if stability_score is not None:
            score = (score + max(0.0, min(float(stability_score), 1.0))) / 2.0
        score -= min(center_distance * 0.2, 0.2)
    elif bbox_type in {"real_bbox", "manual_bbox"}:
        score = 0.98
    else:
        score = 0.75

    if "area_ratio_out_of_range" in reasons or "empty_bbox" in reasons:
        score = min(score, 0.25)
    if "touches_full_image" in reasons:
        score = min(score, 0.35)
    score = round(max(0.0, min(score, 1.0)), 4)
    return BboxQuality(keep=not reasons and score >= 0.45, score=score, reasons=reasons)


def write_csv(path: Path, rows: list[dict[str, Any]], fieldnames: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def write_meta(output_root: Path) -> None:
    class_rows = [
        {
            "category_id": index,
            "canonical_label": food.canonical_label,
            "fallback_label": food.fallback_label,
            "tier": food.tier,
            "group": food.group,
            "aliases": "|".join(food.aliases),
        }
        for index, food in enumerate(FOOD_CLASSES, start=1)
    ]
    write_csv(
        output_root / "meta" / "class_map_v1.csv",
        class_rows,
        ["category_id", "canonical_label", "fallback_label", "tier", "group", "aliases"],
    )
    source_rows = [policy.__dict__ for policy in SOURCE_POLICIES]
    write_csv(
        output_root / "meta" / "source_map.csv",
        source_rows,
        ["source_dataset", "dataset_type", "license_risk", "bbox_type", "product_use", "note"],
    )
    license_rows = [
        {"license_risk": "owned_or_user_authorized", "allow_research_full": "yes", "allow_commercial_candidate": "yes"},
        {"license_risk": "apache_2_0", "allow_research_full": "yes", "allow_commercial_candidate": "yes"},
        {"license_risk": "cc_by_4_0", "allow_research_full": "yes", "allow_commercial_candidate": "yes_with_attribution"},
        {"license_risk": "needs_license_review", "allow_research_full": "yes", "allow_commercial_candidate": "review_before_launch"},
        {"license_risk": "research_only", "allow_research_full": "yes", "allow_commercial_candidate": "no"},
    ]
    write_csv(
        output_root / "meta" / "license_risk.csv",
        license_rows,
        ["license_risk", "allow_research_full", "allow_commercial_candidate"],
    )


def deterministic_split(key: str) -> str:
    bucket = int(hashlib.sha1(key.encode("utf-8")).hexdigest()[:8], 16) % 100
    if bucket < 80:
        return "train"
    if bucket < 90:
        return "val"
    return "test"


def should_include_license(policy: SourcePolicy, license_policy: str) -> bool:
    if license_policy == "research_full":
        return True
    if license_policy == "commercial_candidate":
        return policy.license_risk not in {"research_only"}
    raise ValueError(f"unsupported license_policy: {license_policy}")


def image_record_id(path: Path, split: str, index: int) -> int:
    digest = hashlib.sha1(f"{split}:{path}:{index}".encode("utf-8")).hexdigest()[:8]
    return int(digest, 16)


def load_normalized_rows(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            rows.append(json.loads(line))
    return rows


def _stable_image_key(image_path: Path) -> str:
    try:
        return str(image_path.resolve())
    except OSError:
        return str(image_path)


def _unique_image_name(image_path: Path) -> str:
    digest = hashlib.sha1(_stable_image_key(image_path).encode("utf-8")).hexdigest()[:12]
    suffix = image_path.suffix or ".jpg"
    return f"{image_path.stem}-{digest}{suffix}"


def _copy_image_if_needed(image_path: Path, output_root: Path, split: str) -> str:
    target_dir = output_root / "images" / split
    target_dir.mkdir(parents=True, exist_ok=True)
    target = target_dir / _unique_image_name(image_path)
    if image_path.exists() and not target.exists():
        try:
            shutil.copy2(image_path, target)
        except shutil.SameFileError:
            pass
    return str(Path("images") / split / target.name)


def build_food_rtdetr_v1(
    output_root: Path,
    normalized_jsonl: Path | None = None,
    license_policy: str = "research_full",
    copy_images: bool = True,
) -> dict[str, dict[str, int]]:
    output_root.mkdir(parents=True, exist_ok=True)
    (output_root / "annotations").mkdir(parents=True, exist_ok=True)
    (output_root / "images").mkdir(parents=True, exist_ok=True)
    write_meta(output_root)

    categories = [
        {
            "id": index,
            "name": food.canonical_label,
            "supercategory": food.group,
            "fallback_label": food.fallback_label,
            "tier": food.tier,
        }
        for index, food in enumerate(FOOD_CLASSES, start=1)
    ]
    category_id_by_label = {category["name"]: category["id"] for category in categories}
    coco_by_split: dict[str, dict[str, Any]] = {
        split: {"images": [], "annotations": [], "categories": categories}
        for split in ("train", "val", "test")
    }
    pseudo_rows: list[dict[str, Any]] = []
    image_records: dict[tuple[str, str], int] = {}

    rows = load_normalized_rows(normalized_jsonl) if normalized_jsonl else []
    annotation_id = 1
    for index, row in enumerate(rows, start=1):
        image_path = Path(str(row["image_path"]))
        source_dataset = str(row.get("source_dataset") or "Unknown")
        bbox_type = str(row.get("bbox_type") or get_source_policy(source_dataset).bbox_type)
        source_policy = get_source_policy(source_dataset, bbox_type=bbox_type)
        if not should_include_license(source_policy, license_policy):
            continue

        label = map_label(str(row.get("original_label") or row.get("label") or ""))
        split = str(row.get("split") or deterministic_split(str(image_path))).lower()
        if split not in coco_by_split:
            split = deterministic_split(str(image_path))
        width = int(row.get("width") or 0)
        height = int(row.get("height") or 0)
        if (width <= 0 or height <= 0) and image_path.exists():
            with Image.open(image_path) as image:
                width, height = image.size
        if width <= 0 or height <= 0:
            continue

        bbox_xywh = normalize_bbox(row["bbox"], str(row.get("bbox_format") or "xyxy"))
        bbox_xyxy = xywh_to_xyxy(bbox_xywh)
        quality_signals = row.get("quality_signals") or {}
        quality = score_bbox_quality(
            image_width=width,
            image_height=height,
            bbox_xyxy=bbox_xyxy,
            bbox_type=bbox_type,
            mask_area=quality_signals.get("mask_area"),
            predicted_iou=quality_signals.get("predicted_iou"),
            stability_score=quality_signals.get("stability_score"),
        )
        if not quality.keep and bbox_type.startswith("pseudo"):
            pseudo_rows.append(
                {
                    "image_path": str(image_path),
                    "source_dataset": source_dataset,
                    "original_label": label.original_label,
                    "mapped_label": label.canonical_label,
                    "bbox_type": bbox_type,
                    "license_risk": source_policy.license_risk,
                    "quality_score": quality.score,
                    "keep": "no",
                    "reasons": "|".join(quality.reasons),
                }
            )
            continue

        image_key = (split, _stable_image_key(image_path))
        if image_key in image_records:
            image_id = image_records[image_key]
        else:
            image_id = image_record_id(image_path, split, 0)
            image_records[image_key] = image_id
            file_name = _copy_image_if_needed(image_path, output_root, split) if copy_images else str(image_path)
            coco_by_split[split]["images"].append(
                {
                    "id": image_id,
                    "file_name": file_name,
                    "width": width,
                    "height": height,
                    "source_dataset": source_dataset,
                    "original_label": label.original_label,
                    "mapped_label": label.canonical_label,
                    "fallback_label": label.fallback_label,
                    "bbox_type": bbox_type,
                    "license_risk": source_policy.license_risk,
                }
            )
        coco_by_split[split]["annotations"].append(
            {
                "id": annotation_id,
                "image_id": image_id,
                "category_id": category_id_by_label[label.canonical_label],
                "bbox": [round(v, 2) for v in bbox_xywh],
                "area": round(bbox_xywh[2] * bbox_xywh[3], 2),
                "iscrowd": 0,
                "source_dataset": source_dataset,
                "original_label": label.original_label,
                "mapped_label": label.canonical_label,
                "fallback_label": label.fallback_label,
                "bbox_type": bbox_type,
                "license_risk": source_policy.license_risk,
                "quality_score": quality.score,
            }
        )
        annotation_id += 1
        if bbox_type.startswith("pseudo"):
            pseudo_rows.append(
                {
                    "image_path": str(image_path),
                    "source_dataset": source_dataset,
                    "original_label": label.original_label,
                    "mapped_label": label.canonical_label,
                    "bbox_type": bbox_type,
                    "license_risk": source_policy.license_risk,
                    "quality_score": quality.score,
                    "keep": "yes",
                    "reasons": "",
                }
            )

    for split, coco in coco_by_split.items():
        (output_root / "annotations" / f"{split}.json").write_text(
            json.dumps(coco, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
    write_csv(
        output_root / "meta" / "pseudo_label_score.csv",
        pseudo_rows,
        ["image_path", "source_dataset", "original_label", "mapped_label", "bbox_type", "license_risk", "quality_score", "keep", "reasons"],
    )
    return {
        split: {"images": len(coco["images"]), "annotations": len(coco["annotations"])}
        for split, coco in coco_by_split.items()
    }


def convert_uecfood_to_normalized_jsonl(dataset_root: Path, output_jsonl: Path, source_dataset: str, seed: int = 42) -> int:
    category_path = dataset_root / "category.txt"
    if not category_path.exists():
        raise FileNotFoundError(f"missing category.txt under {dataset_root}")
    categories: dict[str, str] = {}
    with category_path.open("r", encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            chunks = line.strip().split("\t")
            if len(chunks) >= 2 and chunks[0].isdigit():
                categories[chunks[0]] = chunks[1]
    rows: list[dict[str, Any]] = []
    rng = random.Random(seed)
    for category_id, category_name in sorted(categories.items(), key=lambda item: int(item[0])):
        class_dir = dataset_root / category_id
        bbox_path = class_dir / "bb_info.txt"
        if not bbox_path.exists():
            continue
        with bbox_path.open("r", encoding="utf-8", errors="ignore") as handle:
            for line in handle:
                chunks = line.strip().split()
                if len(chunks) < 5 or not chunks[0].split(".")[0].isdigit():
                    continue
                image_stem = chunks[0].rsplit(".", 1)[0]
                image_path = class_dir / f"{image_stem}.jpg"
                if not image_path.exists():
                    image_path = class_dir / f"{chunks[0]}"
                if not image_path.exists():
                    continue
                x1, y1, x2, y2 = [float(v) for v in chunks[1:5]]
                with Image.open(image_path) as image:
                    width, height = image.size
                key = f"{category_id}:{image_stem}:{rng.random()}"
                rows.append(
                    {
                        "image_path": str(image_path),
                        "width": width,
                        "height": height,
                        "source_dataset": source_dataset,
                        "original_label": category_name,
                        "bbox": [x1, y1, x2, y2],
                        "bbox_format": "xyxy",
                        "bbox_type": "real_bbox",
                        "split": deterministic_split(key),
                    }
                )
    output_jsonl.parent.mkdir(parents=True, exist_ok=True)
    with output_jsonl.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
    return len(rows)


def _parse_id_label_file(path: Path) -> dict[int, str]:
    labels: dict[int, str] = {}
    with path.open("r", encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            chunks = line.replace("\t", " ").split()
            if not chunks or not chunks[0].isdigit():
                continue
            labels[int(chunks[0])] = " ".join(chunks[1:]) or f"class_{chunks[0]}"
    return labels


def _resolve_foodseg_labels(dataset_root: Path) -> dict[int, str]:
    labels = dict(FOODSEG103_LABELS)
    for name in ("category.txt", "categories.txt", "classes.txt", "class_names.txt", "labels.txt"):
        for candidate in dataset_root.rglob(name):
            parsed = _parse_id_label_file(candidate)
            if parsed:
                labels.update(parsed)
                return labels
    return labels


def _find_image_for_mask(image_dir: Path, stem: str) -> Path | None:
    for suffix in (".jpg", ".jpeg", ".png", ".JPG", ".JPEG", ".PNG"):
        candidate = image_dir / f"{stem}{suffix}"
        if candidate.exists():
            return candidate
    return None


def _infer_semantic_split(path: Path) -> str | None:
    parts = {part.casefold() for part in path.parts}
    if "train" in parts or "training" in parts:
        return "train"
    if {"val", "valid", "validation", "test", "testing"} & parts:
        return "val"
    return None


def _iter_semantic_mask_pairs(dataset_root: Path) -> Iterable[tuple[Path, Path, str]]:
    seen_masks: set[Path] = set()
    split_names = ("train", "training", "val", "valid", "validation", "test", "testing")
    known_layouts = (
        ("Images/img_dir", "Images/ann_dir"),
        ("img_dir", "ann_dir"),
        ("images", "masks"),
        ("image", "mask"),
        ("JPEGImages", "SegmentationClass"),
    )
    candidate_roots = [dataset_root]
    candidate_roots.extend(path.parent for path in dataset_root.rglob("Images") if path.is_dir())
    candidate_roots.extend(path.parent for path in dataset_root.rglob("img_dir") if path.is_dir())

    for content_root in dict.fromkeys(candidate_roots):
        for image_rel, mask_rel in known_layouts:
            image_base = content_root / image_rel
            mask_base = content_root / mask_rel
            if not image_base.exists() or not mask_base.exists():
                continue
            for split_name in split_names:
                image_dir = image_base / split_name
                mask_dir = mask_base / split_name
                if not image_dir.exists() or not mask_dir.exists():
                    continue
                output_split = "train" if split_name in {"train", "training"} else "val"
                for mask_path in sorted(mask_dir.rglob("*.png")):
                    resolved = mask_path.resolve()
                    if resolved in seen_masks:
                        continue
                    image_path = _find_image_for_mask(image_dir, mask_path.stem)
                    if image_path is None:
                        continue
                    seen_masks.add(resolved)
                    yield mask_path, image_path, output_split

    mask_dir_tokens = {"ann_dir", "mask", "masks", "label", "labels", "annotation", "annotations", "segmentationclass"}
    image_dir_tokens = {"img_dir", "image", "images", "jpegimages", "jpgimages"}
    image_index: dict[str, list[Path]] = {}
    for image_path in dataset_root.rglob("*"):
        if not image_path.is_file() or image_path.suffix.casefold() not in {".jpg", ".jpeg", ".png"}:
            continue
        parts = {part.casefold() for part in image_path.parts}
        if parts & mask_dir_tokens:
            continue
        if parts & image_dir_tokens or image_path.suffix.casefold() in {".jpg", ".jpeg"}:
            image_index.setdefault(image_path.stem, []).append(image_path)

    for mask_path in sorted(dataset_root.rglob("*.png")):
        resolved = mask_path.resolve()
        if resolved in seen_masks:
            continue
        parts = {part.casefold() for part in mask_path.parts}
        if not (parts & mask_dir_tokens):
            continue
        candidates = image_index.get(mask_path.stem) or []
        if not candidates:
            continue
        output_split = _infer_semantic_split(mask_path) or deterministic_split(str(mask_path))
        yield mask_path, candidates[0], output_split


def _load_classification_split_index(dataset_root: Path) -> dict[str, str]:
    split_index: dict[str, str] = {}
    for filename, split in (("train.txt", "train"), ("test.txt", "val"), ("val.txt", "val"), ("validation.txt", "val")):
        path = dataset_root / "meta" / filename
        if not path.exists():
            continue
        with path.open("r", encoding="utf-8", errors="ignore") as handle:
            for line in handle:
                key = line.strip().replace("\\", "/")
                if not key:
                    continue
                key = key.rsplit(".", 1)[0]
                split_index[key] = split
    return split_index


def _classification_split_and_label(dataset_root: Path, image_path: Path, split_index: dict[str, str] | None = None) -> tuple[str, str]:
    try:
        relative_parts = image_path.relative_to(dataset_root).parts
    except ValueError:
        relative_parts = image_path.parts
    split = deterministic_split(str(image_path))
    label = image_path.parent.name
    if len(relative_parts) >= 3 and relative_parts[0].casefold() in {"images", "image", "imgs", "img"}:
        meta_key = "/".join(relative_parts[1:]).rsplit(".", 1)[0]
        if split_index and meta_key in split_index:
            split = split_index[meta_key]
            label = relative_parts[1]
            return split, display_label(label)
    if len(relative_parts) >= 3:
        first = relative_parts[0].casefold()
        if first in CLASSIFICATION_SPLIT_MAP:
            split = CLASSIFICATION_SPLIT_MAP[first]
            label = relative_parts[1]
    elif len(relative_parts) >= 2 and relative_parts[0].casefold() not in {"images", "image", "imgs", "img"}:
        label = relative_parts[0]
    return split, display_label(label)


def _iter_classification_images(dataset_root: Path) -> Iterable[Path]:
    for path in sorted(dataset_root.rglob("*")):
        if not path.is_file() or path.suffix.casefold() not in IMAGE_SUFFIXES:
            continue
        parts = {part.casefold() for part in path.parts}
        if {"mask", "masks", "ann_dir", "annotations", "segmentationclass"} & parts:
            continue
        yield path


def _central_bbox(width: int, height: int, margin_ratio: float) -> list[int]:
    margin_ratio = max(0.0, min(float(margin_ratio), 0.45))
    x1 = int(round(width * margin_ratio))
    y1 = int(round(height * margin_ratio))
    x2 = int(round(width * (1.0 - margin_ratio)))
    y2 = int(round(height * (1.0 - margin_ratio)))
    if x2 <= x1:
        x1, x2 = 0, width
    if y2 <= y1:
        y1, y2 = 0, height
    return [x1, y1, x2, y2]


def _load_class_list(path: Path) -> dict[str, str]:
    labels: dict[str, str] = {}
    with path.open("r", encoding="utf-8", errors="ignore") as handle:
        for index, line in enumerate(handle):
            line = line.strip()
            if not line:
                continue
            chunks = line.replace(",", " ").split(maxsplit=1)
            if chunks[0].isdigit():
                labels[chunks[0]] = display_label(chunks[1] if len(chunks) > 1 else f"class_{chunks[0]}")
            else:
                labels[str(index)] = display_label(line)
    return labels


def _pseudo_single_label_row(
    image_path: Path,
    width: int,
    height: int,
    source_dataset: str,
    original_label: str,
    split: str,
    bbox_margin_ratio: float,
    confidence: float,
) -> dict[str, Any]:
    x1, y1, x2, y2 = _central_bbox(width, height, bbox_margin_ratio)
    return {
        "image_path": str(image_path),
        "width": width,
        "height": height,
        "source_dataset": source_dataset,
        "original_label": original_label,
        "bbox": [x1, y1, x2, y2],
        "bbox_format": "xyxy",
        "bbox_type": "pseudo_single_label",
        "split": split,
        "quality_signals": {
            "mask_area": int((x2 - x1) * (y2 - y1)),
            "predicted_iou": confidence,
            "stability_score": confidence,
        },
    }


def _mask_class_stats_from_image(mask: Image.Image) -> dict[int, list[int]]:
    if mask.mode in {"RGB", "RGBA"}:
        class_mask = mask.split()[0]
    else:
        class_mask = mask.convert("L")
    try:
        import numpy as np

        mask_array = np.asarray(class_mask)
        stats: dict[int, list[int]] = {}
        for class_id in np.unique(mask_array):
            class_value = int(class_id)
            if class_value == 0:
                continue
            ys, xs = np.nonzero(mask_array == class_id)
            if len(xs) == 0:
                continue
            stats[class_value] = [int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max()), int(len(xs))]
        return stats
    except ImportError:
        pass
    width, height = class_mask.size
    pixels = class_mask.load()
    stats: dict[int, list[int]] = {}
    for y in range(height):
        for x in range(width):
            class_id = int(pixels[x, y])
            if class_id == 0:
                continue
            if class_id not in stats:
                stats[class_id] = [x, y, x, y, 0]
            box = stats[class_id]
            box[0] = min(box[0], x)
            box[1] = min(box[1], y)
            box[2] = max(box[2], x)
            box[3] = max(box[3], y)
            box[4] += 1
    return stats


def _mask_class_stats(mask_path: Path) -> dict[int, list[int]]:
    with Image.open(mask_path) as mask:
        return _mask_class_stats_from_image(mask)


def _resolve_uecfoodpix_content_root(dataset_root: Path) -> Path:
    if (dataset_root / "train" / "img").exists() and (dataset_root / "train" / "mask").exists():
        return dataset_root
    for train_dir in dataset_root.rglob("train"):
        if (train_dir / "img").exists() and (train_dir / "mask").exists():
            return train_dir.parent
    return dataset_root


def convert_uecfoodpix_to_normalized_jsonl(
    dataset_root: Path,
    output_jsonl: Path,
    source_dataset: str = "UECFoodPixComplete",
) -> int:
    category_path = dataset_root / "category.txt"
    if not category_path.exists():
        raise FileNotFoundError(f"missing category.txt under {dataset_root}")
    labels = _parse_id_label_file(category_path)
    content_root = _resolve_uecfoodpix_content_root(dataset_root)
    rows: list[dict[str, Any]] = []
    for raw_split, output_split in (("train", "train"), ("test", "val"), ("val", "val")):
        image_dir = content_root / raw_split / "img"
        mask_dir = content_root / raw_split / "mask"
        if not image_dir.exists() or not mask_dir.exists():
            continue
        for mask_path in sorted(mask_dir.glob("*.png")):
            image_path = _find_image_for_mask(image_dir, mask_path.stem)
            if image_path is None:
                continue
            with Image.open(image_path) as image:
                width, height = image.size
            for class_id, (x1, y1, x2, y2, mask_area) in sorted(_mask_class_stats(mask_path).items()):
                rows.append(
                    {
                        "image_path": str(image_path),
                        "width": width,
                        "height": height,
                        "source_dataset": source_dataset,
                        "original_label": labels.get(class_id, f"class_{class_id}"),
                        "bbox": [x1, y1, x2 + 1, y2 + 1],
                        "bbox_format": "xyxy",
                        "bbox_type": "mask_to_bbox",
                        "split": output_split,
                        "quality_signals": {"mask_area": mask_area},
                    }
                )
    output_jsonl.parent.mkdir(parents=True, exist_ok=True)
    with output_jsonl.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
    return len(rows)


def convert_foodseg_to_normalized_jsonl(
    dataset_root: Path,
    output_jsonl: Path,
    source_dataset: str = "FoodSeg103",
) -> int:
    labels = _resolve_foodseg_labels(dataset_root)
    rows: list[dict[str, Any]] = []
    for mask_path, image_path, output_split in _iter_semantic_mask_pairs(dataset_root):
        with Image.open(image_path) as image:
            width, height = image.size
        for class_id, (x1, y1, x2, y2, mask_area) in sorted(_mask_class_stats(mask_path).items()):
            rows.append(
                {
                    "image_path": str(image_path),
                    "width": width,
                    "height": height,
                    "source_dataset": source_dataset,
                    "original_label": labels.get(class_id, f"class_{class_id}"),
                    "bbox": [x1, y1, x2 + 1, y2 + 1],
                    "bbox_format": "xyxy",
                    "bbox_type": "mask_to_bbox",
                    "split": output_split,
                    "quality_signals": {"mask_area": mask_area},
                }
            )
    output_jsonl.parent.mkdir(parents=True, exist_ok=True)
    with output_jsonl.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
    return len(rows)


def _safe_record_stem(value: Any, fallback: str) -> str:
    raw = str(value or fallback)
    stem = Path(raw).stem or fallback
    safe = "".join(ch if ch.isalnum() or ch in {"-", "_"} else "_" for ch in stem)
    return safe.strip("_") or fallback


def _hf_image(value: Any) -> Image.Image:
    if isinstance(value, Image.Image):
        return value
    if isinstance(value, dict):
        if value.get("bytes") is not None:
            import io

            return Image.open(io.BytesIO(value["bytes"]))
        if value.get("path"):
            return Image.open(value["path"])
    raise TypeError(f"unsupported Hugging Face image value: {type(value).__name__}")


def convert_foodseg_hf_records_to_normalized_jsonl(
    records_by_split: dict[str, Iterable[dict[str, Any]]],
    output_jsonl: Path,
    image_output_root: Path,
    source_dataset: str = "FoodSeg103",
) -> int:
    labels = dict(FOODSEG103_LABELS)
    rows: list[dict[str, Any]] = []
    resampling_nearest = getattr(getattr(Image, "Resampling", Image), "NEAREST")
    for split_name, records in records_by_split.items():
        output_split = "train" if split_name.casefold() in {"train", "training"} else "val"
        for record_index, record in enumerate(records):
            image = _hf_image(record.get("image"))
            mask = _hf_image(record.get("label") or record.get("mask") or record.get("segmentation_mask"))
            width, height = image.size
            if mask.size != (width, height):
                mask = mask.resize((width, height), resampling_nearest)
            stem = _safe_record_stem(record.get("id") or record.get("image_id"), f"{split_name}_{record_index:06d}")
            image_path = image_output_root / output_split / f"{stem}.jpg"
            image_path.parent.mkdir(parents=True, exist_ok=True)
            if not image_path.exists():
                image.convert("RGB").save(image_path, quality=95)
            for class_id, (x1, y1, x2, y2, mask_area) in sorted(_mask_class_stats_from_image(mask).items()):
                rows.append(
                    {
                        "image_path": str(image_path),
                        "width": width,
                        "height": height,
                        "source_dataset": source_dataset,
                        "original_label": labels.get(class_id, f"class_{class_id}"),
                        "bbox": [x1, y1, x2 + 1, y2 + 1],
                        "bbox_format": "xyxy",
                        "bbox_type": "mask_to_bbox",
                        "split": output_split,
                        "quality_signals": {"mask_area": mask_area},
                    }
                )
    output_jsonl.parent.mkdir(parents=True, exist_ok=True)
    with output_jsonl.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
    return len(rows)


def convert_foodseg_hf_to_normalized_jsonl(
    dataset_name: str,
    output_jsonl: Path,
    image_output_root: Path,
    source_dataset: str = "FoodSeg103",
    cache_dir: Path | None = None,
) -> int:
    try:
        from datasets import load_dataset
    except ImportError as exc:
        raise RuntimeError("convert-foodseg-hf requires the optional 'datasets' package") from exc
    dataset = load_dataset(dataset_name, cache_dir=str(cache_dir) if cache_dir else None)
    return convert_foodseg_hf_records_to_normalized_jsonl(
        dict(dataset.items()),
        output_jsonl=output_jsonl,
        image_output_root=image_output_root,
        source_dataset=source_dataset,
    )


def _iter_parquet_records(parquet_paths: Iterable[Path]) -> Iterable[dict[str, Any]]:
    try:
        import pyarrow.parquet as pq
    except ImportError as exc:
        raise RuntimeError("convert-foodseg-hf-parquet requires the optional 'pyarrow' package") from exc
    for parquet_path in parquet_paths:
        parquet_file = pq.ParquetFile(parquet_path)
        for batch in parquet_file.iter_batches(batch_size=64):
            yield from batch.to_pylist()


def convert_foodseg_hf_parquet_to_normalized_jsonl(
    train_parquets: Iterable[Path],
    val_parquets: Iterable[Path],
    output_jsonl: Path,
    image_output_root: Path,
    source_dataset: str = "FoodSeg103",
) -> int:
    return convert_foodseg_hf_records_to_normalized_jsonl(
        {
            "train": _iter_parquet_records(train_parquets),
            "validation": _iter_parquet_records(val_parquets),
        },
        output_jsonl=output_jsonl,
        image_output_root=image_output_root,
        source_dataset=source_dataset,
    )


def convert_classification_folder_to_normalized_jsonl(
    dataset_root: Path,
    output_jsonl: Path,
    source_dataset: str,
    bbox_margin_ratio: float = 0.08,
    default_confidence: float = 0.58,
    max_per_class: int = 0,
    seed: int = 42,
) -> int:
    rng = random.Random(seed)
    grouped: dict[tuple[str, str], list[Path]] = {}
    split_index = _load_classification_split_index(dataset_root)
    for image_path in _iter_classification_images(dataset_root):
        split, label = _classification_split_and_label(dataset_root, image_path, split_index)
        grouped.setdefault((split, label), []).append(image_path)

    rows: list[dict[str, Any]] = []
    confidence = round(max(0.0, min(float(default_confidence), 1.0)), 4)
    for (split, label), image_paths in sorted(grouped.items()):
        selected = list(image_paths)
        if max_per_class > 0 and len(selected) > max_per_class:
            rng.shuffle(selected)
            selected = sorted(selected[:max_per_class])
        for image_path in selected:
            with Image.open(image_path) as image:
                width, height = image.size
            if width <= 1 or height <= 1:
                continue
            rows.append(
                _pseudo_single_label_row(
                    image_path=image_path,
                    width=width,
                    height=height,
                    source_dataset=source_dataset,
                    original_label=label,
                    split=split,
                    bbox_margin_ratio=bbox_margin_ratio,
                    confidence=confidence,
                )
            )
    output_jsonl.parent.mkdir(parents=True, exist_ok=True)
    with output_jsonl.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
    return len(rows)


def convert_csv_classification_to_normalized_jsonl(
    image_root: Path,
    labels_csv: Path,
    class_list: Path,
    output_jsonl: Path,
    source_dataset: str,
    split: str,
    bbox_margin_ratio: float = 0.08,
    default_confidence: float = 0.58,
) -> int:
    labels = _load_class_list(class_list)
    confidence = round(max(0.0, min(float(default_confidence), 1.0)), 4)
    output_split = "train" if split.casefold() in {"train", "training"} else "val"
    rows: list[dict[str, Any]] = []
    image_index: dict[str, Path] | None = None
    with labels_csv.open("r", encoding="utf-8", errors="ignore", newline="") as handle:
        reader = csv.reader(handle)
        for chunks in reader:
            if len(chunks) < 2 or chunks[0].strip().casefold() in {"image", "image_name", "filename", "file_name"}:
                continue
            image_name = chunks[0].strip()
            label_id = chunks[1].strip()
            image_path = image_root / image_name
            if not image_path.exists():
                if image_index is None:
                    image_index = {
                        path.name: path
                        for path in image_root.rglob("*")
                        if path.is_file() and path.suffix.casefold() in IMAGE_SUFFIXES
                    }
                image_path = image_index.get(image_name, image_path)
                if not image_path.exists():
                    continue
            with Image.open(image_path) as image:
                width, height = image.size
            if width <= 1 or height <= 1:
                continue
            rows.append(
                _pseudo_single_label_row(
                    image_path=image_path,
                    width=width,
                    height=height,
                    source_dataset=source_dataset,
                    original_label=labels.get(label_id, display_label(label_id)),
                    split=output_split,
                    bbox_margin_ratio=bbox_margin_ratio,
                    confidence=confidence,
                )
            )
    output_jsonl.parent.mkdir(parents=True, exist_ok=True)
    with output_jsonl.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
    return len(rows)


def convert_coco_dataset_to_normalized_jsonl(
    dataset_root: Path,
    output_jsonl: Path,
    splits: tuple[str, ...] = ("train", "val", "test"),
) -> int:
    rows: list[dict[str, Any]] = []
    for split in splits:
        ann_path = dataset_root / "annotations" / f"{split}.json"
        if not ann_path.exists():
            continue
        coco = json.loads(ann_path.read_text(encoding="utf-8"))
        categories = {category["id"]: category.get("name", "") for category in coco.get("categories", [])}
        images = {image["id"]: image for image in coco.get("images", [])}
        for annotation in coco.get("annotations", []):
            image = images.get(annotation.get("image_id"))
            if image is None:
                continue
            file_name = str(image.get("file_name") or "")
            image_path = Path(file_name)
            if not image_path.is_absolute():
                image_path = dataset_root / file_name
            if not image_path.exists():
                continue
            source_dataset = str(annotation.get("source_dataset") or image.get("source_dataset") or "Unknown")
            original_label = str(
                annotation.get("original_label")
                or image.get("original_label")
                or categories.get(annotation.get("category_id"), "")
            )
            rows.append(
                {
                    "image_path": str(image_path),
                    "width": int(image.get("width") or 0),
                    "height": int(image.get("height") or 0),
                    "source_dataset": source_dataset,
                    "original_label": original_label,
                    "bbox": [float(v) for v in annotation.get("bbox", [])],
                    "bbox_format": "xywh",
                    "bbox_type": str(annotation.get("bbox_type") or image.get("bbox_type") or "real_bbox"),
                    "split": split,
                }
            )
    output_jsonl.parent.mkdir(parents=True, exist_ok=True)
    with output_jsonl.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
    return len(rows)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    init_parser = subparsers.add_parser("init-meta")
    init_parser.add_argument("--output-root", type=Path, required=True)

    build_parser = subparsers.add_parser("build")
    build_parser.add_argument("--output-root", type=Path, required=True)
    build_parser.add_argument("--normalized-jsonl", type=Path)
    build_parser.add_argument("--license-policy", choices=["research_full", "commercial_candidate"], default="research_full")
    build_parser.add_argument("--no-copy-images", action="store_true")

    uec_parser = subparsers.add_parser("convert-uec")
    uec_parser.add_argument("--dataset-root", type=Path, required=True)
    uec_parser.add_argument("--output-jsonl", type=Path, required=True)
    uec_parser.add_argument("--source-dataset", required=True)
    uec_parser.add_argument("--seed", type=int, default=42)

    uecpix_parser = subparsers.add_parser("convert-uecfoodpix")
    uecpix_parser.add_argument("--dataset-root", type=Path, required=True)
    uecpix_parser.add_argument("--output-jsonl", type=Path, required=True)
    uecpix_parser.add_argument("--source-dataset", default="UECFoodPixComplete")

    foodseg_parser = subparsers.add_parser("convert-foodseg")
    foodseg_parser.add_argument("--dataset-root", type=Path, required=True)
    foodseg_parser.add_argument("--output-jsonl", type=Path, required=True)
    foodseg_parser.add_argument("--source-dataset", default="FoodSeg103")

    foodseg_hf_parser = subparsers.add_parser("convert-foodseg-hf")
    foodseg_hf_parser.add_argument("--dataset-name", default="EduardoPacheco/FoodSeg103")
    foodseg_hf_parser.add_argument("--output-jsonl", type=Path, required=True)
    foodseg_hf_parser.add_argument("--image-output-root", type=Path, required=True)
    foodseg_hf_parser.add_argument("--source-dataset", default="FoodSeg103")
    foodseg_hf_parser.add_argument("--cache-dir", type=Path)

    foodseg_hf_parquet_parser = subparsers.add_parser("convert-foodseg-hf-parquet")
    foodseg_hf_parquet_parser.add_argument("--train-parquet", type=Path, nargs="+", required=True)
    foodseg_hf_parquet_parser.add_argument("--val-parquet", type=Path, nargs="+", required=True)
    foodseg_hf_parquet_parser.add_argument("--output-jsonl", type=Path, required=True)
    foodseg_hf_parquet_parser.add_argument("--image-output-root", type=Path, required=True)
    foodseg_hf_parquet_parser.add_argument("--source-dataset", default="FoodSeg103")

    class_dir_parser = subparsers.add_parser("convert-class-dir")
    class_dir_parser.add_argument("--dataset-root", type=Path, required=True)
    class_dir_parser.add_argument("--output-jsonl", type=Path, required=True)
    class_dir_parser.add_argument("--source-dataset", required=True)
    class_dir_parser.add_argument("--bbox-margin-ratio", type=float, default=0.08)
    class_dir_parser.add_argument("--default-confidence", type=float, default=0.58)
    class_dir_parser.add_argument("--max-per-class", type=int, default=0)
    class_dir_parser.add_argument("--seed", type=int, default=42)

    class_csv_parser = subparsers.add_parser("convert-class-csv")
    class_csv_parser.add_argument("--image-root", type=Path, required=True)
    class_csv_parser.add_argument("--labels-csv", type=Path, required=True)
    class_csv_parser.add_argument("--class-list", type=Path, required=True)
    class_csv_parser.add_argument("--output-jsonl", type=Path, required=True)
    class_csv_parser.add_argument("--source-dataset", required=True)
    class_csv_parser.add_argument("--split", choices=["train", "val", "test"], required=True)
    class_csv_parser.add_argument("--bbox-margin-ratio", type=float, default=0.08)
    class_csv_parser.add_argument("--default-confidence", type=float, default=0.58)

    coco_parser = subparsers.add_parser("convert-coco")
    coco_parser.add_argument("--dataset-root", type=Path, required=True)
    coco_parser.add_argument("--output-jsonl", type=Path, required=True)
    coco_parser.add_argument("--splits", nargs="+", default=["train", "val", "test"])

    args = parser.parse_args()
    if args.command == "init-meta":
        write_meta(args.output_root)
        print(json.dumps({"output_root": str(args.output_root)}, ensure_ascii=False))
    elif args.command == "build":
        summary = build_food_rtdetr_v1(
            output_root=args.output_root,
            normalized_jsonl=args.normalized_jsonl,
            license_policy=args.license_policy,
            copy_images=not args.no_copy_images,
        )
        print(json.dumps(summary, ensure_ascii=False, indent=2))
    elif args.command == "convert-uec":
        count = convert_uecfood_to_normalized_jsonl(
            dataset_root=args.dataset_root,
            output_jsonl=args.output_jsonl,
            source_dataset=args.source_dataset,
            seed=args.seed,
        )
        print(json.dumps({"rows": count, "output": str(args.output_jsonl)}, ensure_ascii=False))
    elif args.command == "convert-uecfoodpix":
        count = convert_uecfoodpix_to_normalized_jsonl(
            dataset_root=args.dataset_root,
            output_jsonl=args.output_jsonl,
            source_dataset=args.source_dataset,
        )
        print(json.dumps({"rows": count, "output": str(args.output_jsonl)}, ensure_ascii=False))
    elif args.command == "convert-foodseg":
        count = convert_foodseg_to_normalized_jsonl(
            dataset_root=args.dataset_root,
            output_jsonl=args.output_jsonl,
            source_dataset=args.source_dataset,
        )
        print(json.dumps({"rows": count, "output": str(args.output_jsonl)}, ensure_ascii=False))
    elif args.command == "convert-foodseg-hf":
        count = convert_foodseg_hf_to_normalized_jsonl(
            dataset_name=args.dataset_name,
            output_jsonl=args.output_jsonl,
            image_output_root=args.image_output_root,
            source_dataset=args.source_dataset,
            cache_dir=args.cache_dir,
        )
        print(json.dumps({"rows": count, "output": str(args.output_jsonl)}, ensure_ascii=False))
    elif args.command == "convert-foodseg-hf-parquet":
        count = convert_foodseg_hf_parquet_to_normalized_jsonl(
            train_parquets=args.train_parquet,
            val_parquets=args.val_parquet,
            output_jsonl=args.output_jsonl,
            image_output_root=args.image_output_root,
            source_dataset=args.source_dataset,
        )
        print(json.dumps({"rows": count, "output": str(args.output_jsonl)}, ensure_ascii=False))
    elif args.command == "convert-class-dir":
        count = convert_classification_folder_to_normalized_jsonl(
            dataset_root=args.dataset_root,
            output_jsonl=args.output_jsonl,
            source_dataset=args.source_dataset,
            bbox_margin_ratio=args.bbox_margin_ratio,
            default_confidence=args.default_confidence,
            max_per_class=args.max_per_class,
            seed=args.seed,
        )
        print(json.dumps({"rows": count, "output": str(args.output_jsonl)}, ensure_ascii=False))
    elif args.command == "convert-class-csv":
        count = convert_csv_classification_to_normalized_jsonl(
            image_root=args.image_root,
            labels_csv=args.labels_csv,
            class_list=args.class_list,
            output_jsonl=args.output_jsonl,
            source_dataset=args.source_dataset,
            split=args.split,
            bbox_margin_ratio=args.bbox_margin_ratio,
            default_confidence=args.default_confidence,
        )
        print(json.dumps({"rows": count, "output": str(args.output_jsonl)}, ensure_ascii=False))
    elif args.command == "convert-coco":
        count = convert_coco_dataset_to_normalized_jsonl(
            dataset_root=args.dataset_root,
            output_jsonl=args.output_jsonl,
            splits=tuple(args.splits),
        )
        print(json.dumps({"rows": count, "output": str(args.output_jsonl)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
