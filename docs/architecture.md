# 架构与配置

## 默认应用

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

当前相机界面会拒绝没有有效深度数据的拍摄，带深度数据的拍摄也要求 GPU 可达。默认 `.env.example` 关闭 GPU；默认可运行的图片入口是从相册选图。相机自动回退为纯 RGB 分析尚未接通。

研究工具中保留了 Food-GR1/GLM、GroundingDINO、SAM2、FoodSAM/SAM3 与 Metric3D 的不同实验路线。典型计算方式是：识别与分割 → 深度对齐 → 基准面及高度积分 → 体积乘密度得到克重 → 换算营养。无深度图片可在独立服务中使用预测深度。这里不附权重、完整 GPU 依赖或已部署服务。

这些实验路线不是当前 `direct_nutrition` 普通照片请求必经的步骤。训练、数据下载脚本中的 `/root/autodl-tmp` 等路径是原研究环境约定，需要自行配置。

## 本地数据和隐私

`data/*.db`、`data/depth_captures/`、`static/uploads/`、`.env` 和输出文件被 Git 忽略。内置食物示例在空数据库首次初始化时创建。照片识别会将图片发送给已配置的模型服务，Apple Health 访问由系统权限控制。

当前后端面向单用户和受信任环境。服务端多处使用固定用户 `me`；它没有多租户权限隔离。模型输出、健康评分和默认营养目标均需按具体使用场景评估。
