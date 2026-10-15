# Third-party notices

The MIT license in this repository covers the project's own code and the simple SVG placeholders supplied with this release. It does not relicense third-party software, datasets, model weights, API services, trademarks, or material supplied by users.

## Runtime dependencies

Python dependencies are installed from `requirements.txt`, not vendored. Their upstream licenses continue to apply: FastAPI, Uvicorn, Pydantic, python-dotenv, HTTPX, NumPy, Pillow, OpenCV, Google Gen AI SDK, pytest, and pytest-asyncio. The iOS app uses Apple system frameworks under Apple's SDK terms and does not bundle extracted commercial SDKs.

## External services and optional research tools

- Model integrations include Qwen/DashScope, MiMo, Zhipu/GLM, Doubao, DeepSeek, Gemini and compatible self-hosted endpoints. Supply your own credentials and comply with each provider's terms.
- Open Food Facts barcode data is retrieved from its public service. Database contents are subject to [Open Food Facts reuse terms](https://world.openfoodfacts.org/terms-of-use), including ODbL and applicable image/content licenses. This repository does not redistribute that database.
- USDA nutrition clients and inline example values do not constitute a complete or validated nutrition reference. Consult the relevant source when preparing an application dataset.
- Optional scripts reference FoodSAM, SAM/SAM2/SAM3, GroundingDINO, Metric3D, RT-DETR, Hugging Face and associated checkpoints. Obtain code, model weights and their licenses from their maintainers. No external implementation or checkpoint is included here.
- Research datasets referenced by scripts, including FoodSeg103, Food-101, UECFOOD and FoodX, remain subject to their individual access and redistribution terms. Dataset download links do not grant permission to redistribute data or use it commercially. Where a dataset requires an archive password, obtain it from its publisher and configure it locally.

Commercial app packages, extracted resource bundles, advertising/Firebase configuration, localization dumps, logos, fonts and animations from the original working directory are excluded. The retained `CalAI` source-folder and scheme names are historical development identifiers, not a claim of affiliation.
