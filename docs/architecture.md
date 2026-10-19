# 架构与配置

## iOS 本机版（0.2.0）

`APIClient` 将记录请求作为本机命令交给 Swift `LocalDataStore` actor，命令 URL 不会发送到网络。记录在应用沙盒中原子持久化，支持重启恢复、重复提交去重及失败回滚。遇到损坏文件会保留原文件并报错，不用空数据覆盖。模型密钥不存入此文件。

图片和聊天通过 `QwenService` 直接连接阿里云 HTTPS 接口。Key 与授权状态使用设备专属钥匙串保存；未配置或未授权时不发送请求。连接禁止重定向，不使用共享 URL 缓存、Cookie 或系统凭证缓存。照片输出需通过结构和营养边界校验，用户确认后保存本机。

聊天默认只发送对话。开启记录参考后才包含最近 7 天的饮食、饮水、运动、体重及偏好。系统健康权限与第三方 AI 数据授权分别管理。

本机版不连接以下 Python 实验服务，不包含好友动态、云同步、外卖下单、服务端评分或菜谱生成。旧 iOS 深度代码保留作为研究参考，当前拍摄入口使用普通照片直接调用千问。

## 独立 Python 研究服务

iOS SwiftUI App 将图片发到 `POST /v6/describeMeal`。FastAPI 的 `DescribeMealService` 根据 `PHOTO_ANALYSIS_MODE` 选择处理流程，再返回食物列表、营养信息、健康评分与建议。保存记录是独立操作，SQLite 数据保存在 `data/`。

默认示例配置使用 `LLM_PROVIDER=qwen`、`QWEN_MODEL=qwen-vl-plus`、`PHOTO_ANALYSIS_MODE=direct_nutrition`。模型服务的价格、可用区域和模型名以服务商当前信息为准。

## 图片分析模式

| `PHOTO_ANALYSIS_MODE` | 流程 |
| --- | --- |
| `direct_nutrition` | 单次视觉调用返回食物、克重与营养；规则校正及去重，可缓存结果。 |
| `direct_db` | 模型返回估算结果，再以强匹配数据库条目校准营养。 |
| `fast_db` | 模型识别名称与克重，再由数据库换算营养。 |
| `two_pass` | 视觉识别和估重 → 检索营养候选 → 模型复核。 |
| `cloud_depth` | 调用独立部署的 GPU 图片/深度分析服务。 |

数据库模式需要合适的食物与菜谱数据。仓库仅自带小型示例库，未附完整数据库。

`POST /v6/describeMeal/stream` 有单独的阶段事件实现，当前实现区分直接估算和两阶段复核；其他模式在此接口上不与普通接口完全对应。当前 iOS 普通照片入口使用非流式接口。

## 可选深度分析

带深度采集数据的 iOS 请求使用 `/v1/meal-captures`、文件上传、分析任务及餐食确认接口。配置 `DEPTH_PIPELINE_ENABLED`、`DEPTH_PIPELINE_BASE_URL` 和相应鉴权后，后端才能调用外部 GPU 服务。

Python 深度实验要求独立 GPU 服务；`.env.example` 默认关闭 GPU。它不参与 iOS 本机版的图片识别。

研究工具中保留了 Food-GR1/GLM、GroundingDINO、SAM2、FoodSAM/SAM3 与 Metric3D 的不同实验路线。典型计算方式是：识别与分割 → 深度对齐 → 基准面及高度积分 → 体积乘密度得到克重 → 换算营养。无深度图片可在独立服务中使用预测深度。这里不附权重、完整 GPU 依赖或已部署服务。

这些实验路线不是当前 `direct_nutrition` 普通照片请求必经的步骤。训练、数据下载脚本中的 `/root/autodl-tmp` 等路径是原研究环境约定，需要自行配置。

## 本地数据和隐私

`data/*.db`、`data/depth_captures/`、`static/uploads/`、`.env` 和输出文件被 Git 忽略。内置食物示例在空数据库首次初始化时创建。照片识别会将图片发送给已配置的模型服务，Apple Health 访问由系统权限控制。

当前后端面向单用户和受信任环境。服务端多处使用固定用户 `me`；它没有多租户权限隔离。模型输出、健康评分和默认营养目标均需按具体使用场景评估。
