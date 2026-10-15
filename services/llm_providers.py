"""Multi-provider LLM abstraction for food analysis.

Supports:
  - 本地/云端视觉模型             — OpenAI-compatible multimodal
  - 小米 MiMo v2.5              — OpenAI-compatible multimodal
  - 智谱 GLM-4V (Zhipu)       — vision + text, domestic
  - DeepSeek V3                — text-only, domestic, cheap
  - Google Gemini              — vision + text, fallback

Set LLM_PROVIDER in .env: local_qwen_vl | local_vision | mimo | qwen | doubao | zhipu | deepseek | gemini
"""

import asyncio
import base64
import json
import os
import random
import hashlib
import hmac
import time
from abc import ABC, abstractmethod
from pathlib import Path
from typing import Optional

import httpx

PROMPT_PATH = Path(__file__).parent.parent / "prompts" / "food_analysis.txt"
SYSTEM_PROMPT = PROMPT_PATH.read_text()


def _safe_print(message: str) -> None:
    try:
        print(message)
    except OSError:
        pass


def _env_bool(name: str, default: bool = False) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


class LLMProvider(ABC):
    @abstractmethod
    async def analyze_image(self, image_base64: str) -> str: ...
    @abstractmethod
    async def analyze_text(self, description: str) -> str: ...

    async def analyze_image_with_prompt(
        self,
        image_base64: str,
        system_prompt: str,
        user_prompt: str,
        max_tokens: int = 2048,
    ) -> str:
        raise RuntimeError("This provider does not support custom image prompts")

    async def analyze_leftover_percentages(
        self,
        original_foods: list[dict],
        leftover_image_base64: str,
        original_image_base64: str | None = None,
        description: str = "",
    ) -> str:
        raise RuntimeError("This provider does not support leftover percentage analysis")

    async def raw_completion(self, system_prompt: str, user_prompt: str, max_tokens: int = 2048) -> str:
        """Raw completion for meal plans, insights, etc. Override in subclasses."""
        return await self._call([
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ], max_tokens=max_tokens)

    async def _call(self, messages: list[dict], max_tokens: int = 2048) -> str:
        raise NotImplementedError


# ═══════════════════════════════════════════════════════════════════
# 智谱 AI — GLM-4V (视觉 + 文本)
# 文档: https://open.bigmodel.cn/dev/api
# ═══════════════════════════════════════════════════════════════════

class ZhipuProvider(LLMProvider):
    """智谱 GLM-4V — domestic multimodal model with vision."""

    BASE_URL = "https://open.bigmodel.cn/api/paas/v4"
    def __init__(self, api_key: str):
        self.api_key = api_key
        self.vision_model = os.getenv("ZHIPU_VISION_MODEL", "glm-4.6v-flash").strip()
        self.text_model = os.getenv("ZHIPU_TEXT_MODEL", "glm-4-flash").strip()
        self.timeout_seconds = max(10.0, float(os.getenv("ZHIPU_TIMEOUT_SECONDS", "75")))
        self.max_attempts = max(1, int(os.getenv("ZHIPU_MAX_ATTEMPTS", "1")))

    def _auth_headers(self) -> dict:
        return {"Authorization": f"Bearer {self.api_key}"}

    async def _call(self, model: str, messages: list[dict], max_tokens: int = 2048) -> str:
        for attempt in range(self.max_attempts):
            try:
                request_payload = {
                    "model": model,
                    "messages": messages,
                    "temperature": 0.3,
                    "max_tokens": max_tokens,
                }
                if model.startswith("glm-4.6v"):
                    request_payload["thinking"] = {"type": "disabled"}
                async with httpx.AsyncClient(timeout=self.timeout_seconds) as client:
                    resp = await client.post(
                        f"{self.BASE_URL}/chat/completions",
                        headers={
                            **self._auth_headers(),
                            "Content-Type": "application/json",
                        },
                        json=request_payload,
                    )
                    data = resp.json()
                    if "choices" in data:
                        return data["choices"][0]["message"]["content"]
                    error = data.get("error", {}).get("message", str(data))
                    if "rate" in error.lower() or "429" in str(resp.status_code):
                        await asyncio.sleep(2)
                        continue
                    raise RuntimeError(f"Zhipu API error: {error}")
            except httpx.TimeoutException:
                if attempt + 1 < self.max_attempts:
                    await asyncio.sleep(2)
                    continue
                raise
        raise RuntimeError("Zhipu API failed after retries")

    async def analyze_image(self, image_base64: str) -> str:
        messages = [
            {"role": "system", "content": SYSTEM_PROMPT},
            {
                "role": "user",
                "content": [
                    {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{image_base64}"}},
                    {"type": "text", "text": "分析这张食物图片，返回JSON格式的营养数据。"},
                ],
            },
        ]
        return await self._call(self.vision_model, messages, max_tokens=2048)

    async def analyze_image_with_prompt(
        self,
        image_base64: str,
        system_prompt: str,
        user_prompt: str,
        max_tokens: int = 2048,
    ) -> str:
        messages = [
            {"role": "system", "content": system_prompt},
            {
                "role": "user",
                "content": [
                    {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{image_base64}"}},
                    {"type": "text", "text": user_prompt},
                ],
            },
        ]
        return await self._call(self.vision_model, messages, max_tokens=max_tokens)

    async def analyze_text(self, description: str) -> str:
        prompt = (
            f"{SYSTEM_PROMPT}\n\n"
            f"用户描述的食物: \"{description}\"\n"
            f"分析这个食物并返回JSON。"
        )
        messages = [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": prompt},
        ]
        return await self._call(self.text_model, messages, max_tokens=1024)

    async def raw_completion(self, system_prompt: str, user_prompt: str, max_tokens: int = 2048) -> str:
        messages = [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ]
        return await self._call(self.text_model, messages, max_tokens=max_tokens)

    async def analyze_leftover_percentages(
        self,
        original_foods: list[dict],
        leftover_image_base64: str,
        original_image_base64: str | None = None,
        description: str = "",
    ) -> str:
        content = []
        if original_image_base64:
            content.append({"type": "text", "text": "餐前原图:"})
            content.append({"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{original_image_base64}"}})
        content.extend([
            {"type": "text", "text": "食后剩余图:"},
            {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{leftover_image_base64}"}},
            {"type": "text", "text": _leftover_percentage_prompt(original_foods, description)},
        ])
        system_content = (
            "你是营养记录助手。根据餐前原图、食后剩余图和原始食物列表，估计每个原食物的剩余百分比。只返回JSON。"
            if original_image_base64
            else "你是营养记录助手。根据食后剩余图和原始食物列表，估计每个原食物的剩余百分比。只返回JSON。"
        )
        messages = [
            {"role": "system", "content": system_content},
            {"role": "user", "content": content},
        ]
        return await self._call(self.vision_model, messages, max_tokens=2048)


# ═══════════════════════════════════════════════════════════════════
# DeepSeek — V3 (文本-only, 极便宜)
# 文档: https://platform.deepseek.com/api-docs
# ═══════════════════════════════════════════════════════════════════

class DeepSeekProvider(LLMProvider):
    """DeepSeek V3 — domestic, text-only, very affordable.

    DeepSeek doesn't have vision. Image analysis is NOT supported.
    Use text descriptions instead, or pair with a vision provider.
    """

    BASE_URL = "https://api.deepseek.com"
    MODEL = "deepseek-v4-flash"

    def __init__(self, api_key: str):
        self.api_key = api_key
        self.model = os.getenv("DEEPSEEK_MODEL", self.MODEL)
        self.base_url = os.getenv("DEEPSEEK_BASE_URL", self.BASE_URL).rstrip("/")
        self.temperature = float(os.getenv("DEEPSEEK_TEMPERATURE", "0.2") or 0.2)
        self.thinking = os.getenv("DEEPSEEK_THINKING", "disabled").strip().lower()
        self.timeout = float(os.getenv("DEEPSEEK_TIMEOUT_SECONDS", "90") or 90)
        self.trust_env = _env_bool("DEEPSEEK_TRUST_ENV", False)

    async def _call(self, messages: list[dict], max_tokens: int = 2048) -> str:
        for attempt in range(2):
            try:
                request_json = {
                    "model": self.model,
                    "messages": messages,
                    "temperature": self.temperature,
                    "max_tokens": max_tokens,
                }
                if self.thinking in {"enabled", "disabled"}:
                    request_json["thinking"] = {"type": self.thinking}
                async with httpx.AsyncClient(timeout=self.timeout, trust_env=self.trust_env) as client:
                    resp = await client.post(
                        f"{self.base_url}/v1/chat/completions",
                        headers={
                            "Authorization": f"Bearer {self.api_key}",
                            "Content-Type": "application/json",
                        },
                        json=request_json,
                    )
                    data = resp.json()
                    if "choices" in data:
                        message = data["choices"][0].get("message") or {}
                        return str(message.get("content") or "")
                    error = data.get("error", {}).get("message", str(data))
                    raise RuntimeError(f"DeepSeek API error: {error}")
            except httpx.TimeoutException:
                if attempt == 0:
                    await asyncio.sleep(2)
                    continue
                raise
        raise RuntimeError("DeepSeek API failed after retries")

    async def analyze_image(self, image_base64: str) -> str:
        """DeepSeek has no vision. This will always fail gracefully."""
        raise RuntimeError("DeepSeek does not support image analysis. Use text description or switch to a vision provider (zhipu/gemini).")

    async def analyze_text(self, description: str) -> str:
        prompt = (
            f"{SYSTEM_PROMPT}\n\n"
            f"用户描述的食物: \"{description}\"\n"
            f"分析这个食物并返回JSON。"
        )
        messages = [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": prompt},
        ]
        return await self._call(messages, max_tokens=1024)


# ═══════════════════════════════════════════════════════════════════
# 小米 MiMo — OpenAI-compatible multimodal endpoint
# 文档: https://platform.xiaomimimo.com/docs/en-US/api/chat/openai-api
# ═══════════════════════════════════════════════════════════════════

class MimoProvider(LLMProvider):
    """小米 MiMo v2.5 — OpenAI-compatible multimodal model."""

    DEFAULT_BASE_URL = "https://api.xiaomimimo.com/v1"
    DEFAULT_MODEL = "mimo-v2.5"
    TIMEOUT = httpx.Timeout(connect=30.0, read=120.0, write=120.0, pool=30.0)
    PROVIDER_LABEL = "MiMo"

    def __init__(self, api_key: str, model: str | None = None):
        self.api_key = api_key
        self.model = model or os.getenv("MIMO_MODEL", self.DEFAULT_MODEL)
        self.base_url = (os.getenv("MIMO_BASE_URL") or self.DEFAULT_BASE_URL).rstrip("/")
        self.auth_header = (os.getenv("MIMO_AUTH_HEADER") or "api-key").strip().lower()
        self.trust_env = _env_bool("MIMO_TRUST_ENV", False)
        self.temperature = float(os.getenv("MIMO_TEMPERATURE", "0.3") or 0.3)

    @staticmethod
    def _message_text(message: dict) -> str:
        content = message.get("content", "")
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            parts = []
            for item in content:
                if isinstance(item, dict):
                    text = item.get("text")
                    if text:
                        parts.append(str(text))
            return "\n".join(parts)
        return str(content or message.get("reasoning_content") or "")

    @staticmethod
    def _format_transport_error(exc: Exception) -> str:
        message = str(exc).strip()
        if message:
            return f"{type(exc).__name__}: {message}"
        cause = getattr(exc, "__cause__", None) or getattr(exc, "__context__", None)
        if cause:
            cause_message = str(cause).strip() or repr(cause)
            return f"{type(exc).__name__}: {cause_message}"
        return f"{type(exc).__name__}: {repr(exc)}"

    def _headers(self) -> dict[str, str]:
        if self.auth_header in {"authorization", "bearer"}:
            auth = {"Authorization": f"Bearer {self.api_key}"}
        else:
            auth = {"api-key": self.api_key}
        return {**auth, "Content-Type": "application/json"}

    async def _call(self, messages: list[dict], max_tokens: int = 4096) -> str:
        last_error = ""
        for attempt in range(3):
            try:
                async with httpx.AsyncClient(timeout=self.TIMEOUT, trust_env=self.trust_env) as client:
                    resp = await client.post(
                        f"{self.base_url}/chat/completions",
                        headers=self._headers(),
                        json={
                            "model": self.model,
                            "messages": messages,
                            "temperature": self.temperature,
                            "max_completion_tokens": max_tokens,
                        },
                    )
                    try:
                        data = resp.json()
                    except ValueError:
                        last_error = f"HTTP {resp.status_code}: {resp.text[:500]}"
                        if resp.status_code in (429, 500, 502, 503, 504) and attempt < 2:
                            await asyncio.sleep(2 * (attempt + 1))
                            continue
                        raise RuntimeError(f"{self.PROVIDER_LABEL} API error: {last_error}")
                    if "choices" in data and data["choices"]:
                        return self._message_text(data["choices"][0].get("message") or {})
                    error = data.get("error", {})
                    if isinstance(error, dict):
                        error = error.get("message") or error
                    last_error = str(error or data)
                    if resp.status_code in (429, 500, 502, 503, 504) and attempt < 2:
                        await asyncio.sleep(2 * (attempt + 1))
                        continue
                    raise RuntimeError(f"{self.PROVIDER_LABEL} API error: {last_error}")
            except (httpx.TimeoutException, httpx.RemoteProtocolError, httpx.ConnectError) as exc:
                last_error = self._format_transport_error(exc)
                if attempt < 2:
                    await asyncio.sleep(2 * (attempt + 1))
                    continue
                raise RuntimeError(f"{self.PROVIDER_LABEL} API error: {last_error}") from exc
        raise RuntimeError(f"{self.PROVIDER_LABEL} API failed after retries: {last_error}")

    async def analyze_image(self, image_base64: str) -> str:
        messages = [
            {"role": "system", "content": SYSTEM_PROMPT},
            {
                "role": "user",
                "content": [
                    {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{image_base64}"}},
                    {"type": "text", "text": "分析这张食物图片，返回JSON格式的完整营养数据。"},
                ],
            },
        ]
        return await self._call(messages, max_tokens=4096)

    async def analyze_image_with_prompt(
        self,
        image_base64: str,
        system_prompt: str,
        user_prompt: str,
        max_tokens: int = 4096,
    ) -> str:
        messages = [
            {"role": "system", "content": system_prompt},
            {
                "role": "user",
                "content": [
                    {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{image_base64}"}},
                    {"type": "text", "text": user_prompt},
                ],
            },
        ]
        return await self._call(messages, max_tokens=max_tokens)

    async def analyze_text(self, description: str) -> str:
        prompt = f"{SYSTEM_PROMPT}\n\n用户描述的食物: \"{description}\"\n分析并返回JSON。"
        messages = [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": prompt},
        ]
        return await self._call(messages, max_tokens=2048)

    async def raw_completion(self, system_prompt: str, user_prompt: str, max_tokens: int = 2048) -> str:
        return await self._call([
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ], max_tokens=max_tokens)

    async def analyze_leftover_percentages(
        self,
        original_foods: list[dict],
        leftover_image_base64: str,
        original_image_base64: str | None = None,
        description: str = "",
    ) -> str:
        content = []
        if original_image_base64:
            content.append({"type": "text", "text": "餐前原图:"})
            content.append({"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{original_image_base64}"}})
        content.extend([
            {"type": "text", "text": "食后剩余图:"},
            {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{leftover_image_base64}"}},
            {"type": "text", "text": _leftover_percentage_prompt(original_foods, description)},
        ])
        messages = [
            {"role": "system", "content": "你是营养记录助手。估计每个原食物的剩余百分比，只返回JSON。"},
            {"role": "user", "content": content},
        ]
        return await self._call(messages, max_tokens=2048)


class LocalQwenVLProvider(MimoProvider):
    """Self-hosted OpenAI-compatible multimodal endpoint."""

    DEFAULT_BASE_URL = "http://127.0.0.1:18000/v1"
    DEFAULT_MODEL = "MiniCPM-V-4_5"
    PROVIDER_LABEL = "MiniCPM-V"
    TIMEOUT = httpx.Timeout(connect=10.0, read=180.0, write=180.0, pool=30.0)

    def __init__(self, api_key: str, model: str | None = None):
        self.api_key = api_key
        self.model = model or os.getenv("LOCAL_VISION_MODEL") or os.getenv("LOCAL_QWEN_VL_MODEL", self.DEFAULT_MODEL)
        self.base_url = (os.getenv("LOCAL_QWEN_VL_BASE_URL") or self.DEFAULT_BASE_URL).rstrip("/")
        self.auth_header = (os.getenv("LOCAL_QWEN_VL_AUTH_HEADER") or "authorization").strip().lower()
        self.trust_env = _env_bool("LOCAL_QWEN_VL_TRUST_ENV", False)
        self.temperature = float(os.getenv("LOCAL_QWEN_VL_TEMPERATURE", "0") or 0)
        self.PROVIDER_LABEL = os.getenv("LOCAL_VISION_LABEL", self.PROVIDER_LABEL)


# ═══════════════════════════════════════════════════════════════════
# 通义千问 Qwen-VL-Max — 阿里云视觉模型
# 文档: https://help.aliyun.com/zh/model-studio/visual-understanding
# ═══════════════════════════════════════════════════════════════════

class QwenVLProvider(LLMProvider):
    """通义千问 Qwen-VL-Max — 国内最强视觉模型之一。

    131K 上下文，8192 输出 token。
    免费额度: 新用户 100 万 tokens
    """

    BASE_URL = "https://dashscope.aliyuncs.com/compatible-mode/v1"
    MODEL = "qwen-vl-max"

    def __init__(self, api_key: str):
        self.api_key = api_key
        self.model = os.getenv("QWEN_MODEL", self.MODEL)
        self.trust_env = _env_bool("QWEN_TRUST_ENV", False)
        self.temperature = float(os.getenv("QWEN_TEMPERATURE", "0") or 0)

    async def _call(self, messages: list[dict], max_tokens: int = 4096) -> str:
        for attempt in range(2):
            try:
                async with httpx.AsyncClient(timeout=90, trust_env=self.trust_env) as client:
                    resp = await client.post(
                        f"{self.BASE_URL}/chat/completions",
                        headers={
                            "Authorization": f"Bearer {self.api_key}",
                            "Content-Type": "application/json",
                        },
                        json={
                            "model": self.model,
                            "messages": messages,
                            "temperature": self.temperature,
                            "max_tokens": max_tokens,
                        },
                    )
                    data = resp.json()
                    if "choices" in data:
                        return data["choices"][0]["message"]["content"]
                    error = data.get("error", {}).get("message", str(data))
                    if "rate" in error.lower() or "429" in str(resp.status_code):
                        await asyncio.sleep(2)
                        continue
                    raise RuntimeError(f"QwenVL API error: {error}")
            except httpx.TimeoutException:
                if attempt == 0:
                    await asyncio.sleep(2)
                    continue
                raise
        raise RuntimeError("QwenVL API failed after retries")

    async def analyze_image(self, image_base64: str) -> str:
        messages = [
            {"role": "system", "content": SYSTEM_PROMPT},
            {
                "role": "user",
                "content": [
                    {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{image_base64}"}},
                    {"type": "text", "text": "分析这张食物图片，返回JSON格式的完整营养数据。"},
                ],
            },
        ]
        return await self._call(messages, max_tokens=4096)

    async def analyze_image_with_prompt(
        self,
        image_base64: str,
        system_prompt: str,
        user_prompt: str,
        max_tokens: int = 4096,
    ) -> str:
        messages = [
            {"role": "system", "content": system_prompt},
            {
                "role": "user",
                "content": [
                    {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{image_base64}"}},
                    {"type": "text", "text": user_prompt},
                ],
            },
        ]
        return await self._call(messages, max_tokens=max_tokens)

    async def analyze_text(self, description: str) -> str:
        prompt = f"{SYSTEM_PROMPT}\n\n用户描述的食物: \"{description}\"\n分析并返回JSON。"
        messages = [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": prompt},
        ]
        return await self._call(messages, max_tokens=2048)

    async def analyze_leftover_percentages(
        self,
        original_foods: list[dict],
        leftover_image_base64: str,
        original_image_base64: str | None = None,
        description: str = "",
    ) -> str:
        content = []
        if original_image_base64:
            content.append({"type": "text", "text": "餐前原图:"})
            content.append({"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{original_image_base64}"}})
        content.extend([
            {"type": "text", "text": "食后剩余图:"},
            {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{leftover_image_base64}"}},
            {"type": "text", "text": _leftover_percentage_prompt(original_foods, description)},
        ])
        messages = [
            {"role": "system", "content": "你是营养记录助手。估计每个原食物的剩余百分比，只返回JSON。"},
            {"role": "user", "content": content},
        ]
        return await self._call(messages, max_tokens=2048)

    async def raw_completion(self, system_prompt: str, user_prompt: str, max_tokens: int = 2048) -> str:
        """Raw completion without food analysis system prompt. For meal plans, insights, etc."""
        return await self._call([
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ], max_tokens=max_tokens)


# ═══════════════════════════════════════════════════════════════════
# 豆包 Vision — 字节跳动火山引擎 (骨架，API 格式与 OpenAI 兼容)
# 文档: https://www.volcengine.com/docs/6791/1310291
# ═══════════════════════════════════════════════════════════════════

class DoubaoVisionProvider(LLMProvider):
    """豆包视觉模型 — 字节跳动/火山引擎。

    最新: Doubao-Seed-2.0-lite (全模态)
    """

    BASE_URL = "https://ark.cn-beijing.volces.com/api/v3"
    MODEL = "doubao-seed-2-0-lite-250428"

    def __init__(self, api_key: str):
        self.api_key = api_key

    async def _call(self, messages: list[dict], max_tokens: int = 4096) -> str:
        for attempt in range(2):
            try:
                async with httpx.AsyncClient(timeout=90) as client:
                    resp = await client.post(
                        f"{self.BASE_URL}/chat/completions",
                        headers={
                            "Authorization": f"Bearer {self.api_key}",
                            "Content-Type": "application/json",
                        },
                        json={
                            "model": self.MODEL,
                            "messages": messages,
                            "temperature": 0.3,
                            "max_tokens": max_tokens,
                        },
                    )
                    data = resp.json()
                    if "choices" in data:
                        return data["choices"][0]["message"]["content"]
                    error = data.get("error", {}).get("message", str(data))
                    raise RuntimeError(f"DoubaoVision API error: {error}")
            except httpx.TimeoutException:
                if attempt == 0:
                    await asyncio.sleep(2)
                    continue
                raise
        raise RuntimeError("DoubaoVision API failed after retries")

    async def analyze_image(self, image_base64: str) -> str:
        messages = [
            {"role": "system", "content": SYSTEM_PROMPT},
            {
                "role": "user",
                "content": [
                    {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{image_base64}"}},
                    {"type": "text", "text": "分析食物图片，返回JSON营养数据。"},
                ],
            },
        ]
        return await self._call(messages, max_tokens=4096)

    async def analyze_image_with_prompt(
        self,
        image_base64: str,
        system_prompt: str,
        user_prompt: str,
        max_tokens: int = 4096,
    ) -> str:
        messages = [
            {"role": "system", "content": system_prompt},
            {
                "role": "user",
                "content": [
                    {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{image_base64}"}},
                    {"type": "text", "text": user_prompt},
                ],
            },
        ]
        return await self._call(messages, max_tokens=max_tokens)

    async def analyze_text(self, description: str) -> str:
        prompt = f"{SYSTEM_PROMPT}\n\n用户描述: \"{description}\"\n分析并返回JSON。"
        messages = [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": prompt},
        ]
        return await self._call(messages, max_tokens=2048)

    async def raw_completion(self, system_prompt: str, user_prompt: str, max_tokens: int = 2048) -> str:
        return await self._call([
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ], max_tokens=max_tokens)

    async def analyze_leftover_percentages(
        self,
        original_foods: list[dict],
        leftover_image_base64: str,
        original_image_base64: str | None = None,
        description: str = "",
    ) -> str:
        content = []
        if original_image_base64:
            content.append({"type": "text", "text": "餐前原图:"})
            content.append({"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{original_image_base64}"}})
        content.extend([
            {"type": "text", "text": "食后剩余图:"},
            {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{leftover_image_base64}"}},
            {"type": "text", "text": _leftover_percentage_prompt(original_foods, description)},
        ])
        messages = [
            {"role": "system", "content": "你是营养记录助手。估计每个原食物的剩余百分比，只返回JSON。"},
            {"role": "user", "content": content},
        ]
        return await self._call(messages, max_tokens=2048)


# ═══════════════════════════════════════════════════════════════════
# Google Gemini (fallback)
# ═══════════════════════════════════════════════════════════════════

class GeminiProvider(LLMProvider):
    """Google Gemini — existing provider, kept as fallback."""

    def __init__(self, api_key: str):
        from google import genai
        from google.genai import types as genai_types
        self.client = genai.Client(api_key=api_key, http_options={"api_version": "v1alpha"})
        self.model = "gemini-2.5-flash"
        self._types = genai_types

    async def analyze_image(self, image_base64: str) -> str:
        try:
            image_bytes = base64.b64decode(image_base64)
        except Exception:
            raise ValueError("Invalid base64 image data")

        for attempt in range(2):
            try:
                image_part = self._types.Part.from_bytes(data=image_bytes, mime_type="image/jpeg")
                config = self._types.GenerateContentConfig(
                    system_instruction=SYSTEM_PROMPT,
                    temperature=0.3,
                    max_output_tokens=2048,
                )
                response = self.client.models.generate_content(model=self.model, config=config, contents=[image_part])
                return response.text
            except Exception as e:
                if attempt == 0 and ("503" in str(e) or "429" in str(e)): await asyncio.sleep(2); continue
                raise

    async def analyze_image_with_prompt(
        self,
        image_base64: str,
        system_prompt: str,
        user_prompt: str,
        max_tokens: int = 2048,
    ) -> str:
        try:
            image_bytes = base64.b64decode(image_base64)
        except Exception:
            raise ValueError("Invalid base64 image data")

        for attempt in range(2):
            try:
                image_part = self._types.Part.from_bytes(data=image_bytes, mime_type="image/jpeg")
                config = self._types.GenerateContentConfig(
                    system_instruction=system_prompt,
                    temperature=0.3,
                    max_output_tokens=max_tokens,
                )
                response = self.client.models.generate_content(
                    model=self.model,
                    config=config,
                    contents=[image_part, user_prompt],
                )
                return response.text
            except Exception as e:
                if attempt == 0 and ("503" in str(e) or "429" in str(e)):
                    await asyncio.sleep(2)
                    continue
                raise

    async def analyze_text(self, description: str) -> str:
        prompt = f"{SYSTEM_PROMPT}\n\n用户描述的食物: \"{description}\"\n分析并返回JSON。"
        for attempt in range(2):
            try:
                config = self._types.GenerateContentConfig(temperature=0.3, max_output_tokens=1024)
                response = self.client.models.generate_content(model=self.model, config=config, contents=[prompt])
                return response.text
            except Exception as e:
                if attempt == 0 and ("503" in str(e) or "429" in str(e)): await asyncio.sleep(2); continue
                raise

    async def raw_completion(self, system_prompt: str, user_prompt: str, max_tokens: int = 2048) -> str:
        for attempt in range(2):
            try:
                config = self._types.GenerateContentConfig(
                    system_instruction=system_prompt, temperature=0.3, max_output_tokens=max_tokens)
                response = self.client.models.generate_content(model=self.model, config=config, contents=[user_prompt])
                return response.text
            except Exception as e:
                if attempt == 0 and ("503" in str(e) or "429" in str(e)): await asyncio.sleep(2); continue
                raise

    async def analyze_leftover_percentages(
        self,
        original_foods: list[dict],
        leftover_image_base64: str,
        original_image_base64: str | None = None,
        description: str = "",
    ) -> str:
        try:
            leftover_bytes = base64.b64decode(leftover_image_base64)
            original_bytes = base64.b64decode(original_image_base64) if original_image_base64 else None
        except Exception:
            raise ValueError("Invalid base64 image data")

        for attempt in range(2):
            try:
                parts = []
                if original_bytes:
                    parts.extend([
                        "餐前原图:",
                        self._types.Part.from_bytes(data=original_bytes, mime_type="image/jpeg"),
                    ])
                parts.extend([
                    "食后剩余图:",
                    self._types.Part.from_bytes(data=leftover_bytes, mime_type="image/jpeg"),
                    _leftover_percentage_prompt(original_foods, description),
                ])
                system_instruction = (
                    "你是营养记录助手。根据餐前原图、食后剩余图和原始食物列表，估计每个原食物的剩余百分比。只返回JSON。"
                    if original_bytes
                    else "你是营养记录助手。根据食后剩余图和原始食物列表，估计每个原食物的剩余百分比。只返回JSON。"
                )
                config = self._types.GenerateContentConfig(
                    system_instruction=system_instruction,
                    temperature=0.2,
                    max_output_tokens=2048,
                )
                response = self.client.models.generate_content(model=self.model, config=config, contents=parts)
                return response.text
            except Exception as e:
                if attempt == 0 and ("503" in str(e) or "429" in str(e)):
                    await asyncio.sleep(2)
                    continue
                raise


def _leftover_percentage_prompt(original_foods: list[dict], description: str = "") -> str:
    user_note = f"\n用户补充描述: {description.strip()}\n" if description and description.strip() else ""
    return (
        "原始食物列表如下。请只针对这些原始食物估计食后剩余百分比，0表示吃完，100表示完全没吃。\n"
        f"{json.dumps(original_foods, ensure_ascii=False)}\n\n"
        f"{user_note}"
        "返回严格JSON，不要Markdown，格式:\n"
        "{\"items\":[{\"id\":\"原始id\",\"name\":\"食物名\",\"remaining_percent\":0,\"confidence\":0.0,\"reason\":\"简短依据\"}],\"notes\":\"\"}\n"
        "如果某个食物在剩余图里看不到，remaining_percent填0。如果看不清，给出保守估计并降低confidence。"
    )


# ═══════════════════════════════════════════════════════════════════
# Provider factory
# ═══════════════════════════════════════════════════════════════════

class FallbackProvider(LLMProvider):
    """Try configured providers in order so one flaky model does not break scans."""

    def __init__(self, providers: list[tuple[str, LLMProvider]]):
        self.providers = providers

    async def _try(self, method_name: str, *args, **kwargs) -> str:
        errors: list[str] = []
        for name, provider in self.providers:
            try:
                method = getattr(provider, method_name)
                return await method(*args, **kwargs)
            except Exception as exc:
                message = str(exc)
                errors.append(f"{name}: {type(exc).__name__}: {message[:180]}")
                _safe_print(f"[LLM] {name}.{method_name} failed: {type(exc).__name__}: {message[:180]}")
                continue
        raise RuntimeError(f"All LLM providers failed for {method_name}: {' | '.join(errors[-4:])}")

    async def analyze_image(self, image_base64: str) -> str:
        return await self._try("analyze_image", image_base64)

    async def analyze_text(self, description: str) -> str:
        return await self._try("analyze_text", description)

    async def analyze_image_with_prompt(
        self,
        image_base64: str,
        system_prompt: str,
        user_prompt: str,
        max_tokens: int = 2048,
    ) -> str:
        return await self._try(
            "analyze_image_with_prompt",
            image_base64,
            system_prompt,
            user_prompt,
            max_tokens=max_tokens,
        )

    async def analyze_leftover_percentages(
        self,
        original_foods: list[dict],
        leftover_image_base64: str,
        original_image_base64: str | None = None,
        description: str = "",
    ) -> str:
        return await self._try(
            "analyze_leftover_percentages",
            original_foods,
            leftover_image_base64,
            original_image_base64,
            description,
        )

    async def raw_completion(self, system_prompt: str, user_prompt: str, max_tokens: int = 2048) -> str:
        return await self._try("raw_completion", system_prompt, user_prompt, max_tokens=max_tokens)


def create_provider() -> LLMProvider:
    """Create LLM provider based on LLM_PROVIDER env var.

    Priority: local vision > MiMo > Qwen > Doubao > Zhipu > DeepSeek > Gemini
    Set LLM_PROVIDER to force: local_qwen_vl | local_vision | qwen_local | mimo | qwen | doubao | zhipu | deepseek | gemini
    """
    provider = os.getenv("LLM_PROVIDER", "").lower()
    provider_aliases = {
        "qwen_local": "local_qwen_vl",
        "local_qwen": "local_qwen_vl",
        "local_vision": "local_qwen_vl",
        "minicpm": "local_qwen_vl",
        "minicpm_v": "local_qwen_vl",
        "qwen2_5_vl": "local_qwen_vl",
    }
    provider = provider_aliases.get(provider, provider)
    fallback_enabled = os.getenv("LLM_FALLBACK_ENABLED", "true").lower() not in {"0", "false", "no"}
    configured: list[tuple[str, LLMProvider]] = []

    # Self-hosted vision service, OpenAI-compatible.
    local_qwen_vl_key = os.getenv("LOCAL_QWEN_VL_API_KEY", "")
    if local_qwen_vl_key:
        configured.append(("local_qwen_vl", LocalQwenVLProvider(local_qwen_vl_key)))

    # Xiaomi MiMo v2.5
    mimo_key = os.getenv("MIMO_API_KEY", "")
    if mimo_key:
        configured.append(("mimo", MimoProvider(mimo_key)))

    # Qwen-VL-Max (best domestic vision model, 131K context)
    qwen_key = os.getenv("QWEN_API_KEY", "")
    if qwen_key:
        configured.append(("qwen", QwenVLProvider(qwen_key)))

    # Doubao Vision (ByteDance, full-modal)
    doubao_key = os.getenv("DOUBAO_API_KEY", "")
    if doubao_key:
        configured.append(("doubao", DoubaoVisionProvider(doubao_key)))

    # Zhipu GLM-4V (reliable domestic vision)
    zhipu_key = os.getenv("ZHIPU_API_KEY", "")
    if zhipu_key:
        configured.append(("zhipu", ZhipuProvider(zhipu_key)))

    # DeepSeek V3 (text only, no vision)
    deepseek_key = os.getenv("DEEPSEEK_API_KEY", "")
    if deepseek_key:
        configured.append(("deepseek", DeepSeekProvider(deepseek_key)))

    # Gemini fallback
    gemini_key = os.getenv("GEMINI_API_KEY", "")
    if gemini_key:
        configured.append(("gemini", GeminiProvider(gemini_key)))

    order = ["local_qwen_vl", "mimo", "qwen", "doubao", "zhipu", "deepseek", "gemini"]
    if provider:
        order = [provider] + ([name for name in order if name != provider] if fallback_enabled else [])
    ordered = [
        item
        for name in order
        for item in configured
        if item[0] == name
    ]
    if ordered:
        if len(ordered) == 1:
            _safe_print(f"[LLM] Using {ordered[0][0]}")
            return ordered[0][1]
        if fallback_enabled:
            _safe_print(f"[LLM] Using fallback chain: {' -> '.join(name for name, _ in ordered)}")
            return FallbackProvider(ordered)
        _safe_print(f"[LLM] Using {ordered[0][0]}")
        return ordered[0][1]

    raise RuntimeError(
        "No LLM provider configured. Set one of:\n"
        "  LOCAL_QWEN_VL_API_KEY=xxx  (自部署视觉模型 OpenAI-compatible)\n"
        "  MIMO_API_KEY=xxx         (小米 MiMo v2.5)\n"
        "  QWEN_API_KEY=xxx         (通义千问 Qwen-VL-Max, 推荐)\n"
        "  DOUBAO_API_KEY=xxx       (豆包 Doubao-Seed-2.0)\n"
        "  ZHIPU_API_KEY=xxx        (智谱 GLM-4V)\n"
        "  DEEPSEEK_API_KEY=xxx     (DeepSeek V3, text only)\n"
        "  GEMINI_API_KEY=xxx       (Google Gemini)"
    )
