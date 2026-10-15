"""Configuration — API keys, model settings, defaults."""

import os
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).parent / ".env")

# Gemini API
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY", "")
GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-2.5-flash")

# Default nutrition goals (Harvard / USDA DRI guidelines)
DEFAULT_GOAL = {
    "calories": 2000,
    "protein": 50,     # g
    "carbs": 250,      # g
    "fat": 65,         # g
    "fiber": 25,       # g
    "sugar": 50,       # g (limit)
    "sodium": 2300,    # mg (limit)
    "water_ml": 2000,
}

# Server
HOST = os.getenv("HOST", "0.0.0.0")
PORT = int(os.getenv("PORT", "8001"))
