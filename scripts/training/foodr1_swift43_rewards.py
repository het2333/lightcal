"""ms-swift 4.3 reward registry adapter for the official Food-R1 rewards.

The released Food-R1 plugin registers rewards against the older
`swift.plugin.orms` location. ms-swift 4.3 reads `swift.rewards.orms` and
instantiates reward classes with `args=...`, so this wrapper keeps the official
reward implementation while adapting registration and constructors.
"""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
from typing import List

from swift.rewards import ORM, orms


_OFFICIAL_REWARDS = Path(
    os.environ.get(
        "FOODR1_OFFICIAL_REWARDS",
        "/root/autodl-tmp/glm_food_r1_experiment/Food-R1/foodr1/rewards.py",
    )
)

_spec = importlib.util.spec_from_file_location("_official_foodr1_rewards", _OFFICIAL_REWARDS)
if _spec is None or _spec.loader is None:
    raise RuntimeError(f"Cannot load official Food-R1 rewards from {_OFFICIAL_REWARDS}")
_official = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_official)


class _FoodR1RewardAdapter(ORM):
    official_cls = None

    def __init__(self, args=None, **kwargs):
        super().__init__(args=args, **kwargs)
        self._impl = self.official_cls()


class IngredientFormatReward(_FoodR1RewardAdapter):
    official_cls = _official.IngredientFormatReward

    def __call__(self, completions, solution=None, dataset=None, **kwargs) -> List[float]:
        return self._impl(completions=completions, solution=solution, dataset=dataset, **kwargs)


class IngredientMatchReward(_FoodR1RewardAdapter):
    official_cls = _official.IngredientMatchReward

    def __call__(self, completions, solution, dataset=None, **kwargs) -> List[float]:
        return self._impl(completions=completions, solution=solution, dataset=dataset, **kwargs)


class IngredientQuantityMatchReward(_FoodR1RewardAdapter):
    official_cls = _official.IngredientQuantityMatchReward

    def __call__(self, completions, solution, dataset=None, **kwargs) -> List[float]:
        return self._impl(completions=completions, solution=solution, dataset=dataset, **kwargs)


class TotalKcalExactMatchReward(_FoodR1RewardAdapter):
    official_cls = _official.TotalKcalExactMatchReward

    def __call__(self, completions, solution, dataset=None, **kwargs) -> List[float]:
        return self._impl(completions=completions, solution=solution, dataset=dataset, **kwargs)


orms["ingredient_format"] = IngredientFormatReward
orms["ingredient_match"] = IngredientMatchReward
orms["ingredient_quantity_match"] = IngredientQuantityMatchReward
orms["total_kcal_exact"] = TotalKcalExactMatchReward
