# App Store 发布准备

本机版：0.2.0（构建 2），最低 iOS 17.0。默认产品标识为 `com.etheralia.lightcal`；发布者需使用自己有权限的标识与开发团队。

## 产品说明

LightCal 在手机保存饮食、饮水、运动、体重、睡眠和断食记录，无需注册应用账户或部署服务器。可在设置中填写自己的阿里云百炼 API Key，通过通义千问识别餐食照片和进行饮食聊天。模型调用费用由用户的百炼账户承担，App 本身不销售模型额度。

AI 结果为估算，用户检查后再保存，不能替代医疗建议。无好友动态、外卖下单或开发者服务器云同步。

## 审核操作说明

1. 启动后可直接手动记录餐食、补水、记录体重或查看本机统计，无登录流程。
2. “我的 → 设置 → 千问 API Key”中填写百炼 Key，选择所属地域，阅读数据说明并开启授权，点击“验证并保存”。也可从千问聊天页直接打开设置。
3. 用相机或相册选择食物照片后，千问给出估算，用户可检查和修改后保存。
4. 千问聊天默认仅发送对话；结合本机记录需独立开启开关。撤回授权立即生效，重新授权需验证。
5. Apple 健康和语音输入需要相应系统权限；手动记录不需要这些权限。

AI 功能需要有效 Key 及模型权限。审核账号或专用审核 Key 如有需要，应由发布者通过 App Store Connect 的审核备注安全提供，不应提交到公开仓库。

## 签名构建

```bash
xcodebuild -project ios/CalAI.xcodeproj -scheme CalAI \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath /path/to/LightCal.xcarchive \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID -allowProvisioningUpdates archive
```

使用 Xcode Organizer 或 `xcodebuild -exportArchive` 的 `app-store-connect` 导出方式上传。上传成功、处理完成、提交审核和商店公开发布是不同状态，均需核对 App Store Connect 的实际结果。

已包含原创 1024px App Icon、系统权限说明、第三方 AI 功能相关数据类别及 UserDefaults 必需理由清单。百炼可能按其政策留存调用内容，因此不能将 App Store 隐私标签简单填写为“不收集数据”；需如实核对可选照片、健康/健身信息、用户内容和鉴权关联标识的功能用途。上架前仍需在 App Store Connect 核对实际 App 记录、版本/构建号、截图、年龄分级、AI 数据披露、隐私政策链接、支持信息、销售地区和合规声明。不得用测试替身冒充真实模型验证结果。

建议隐私政策链接为公开仓库中的 `docs/privacy.md` 页面；发布者应核对其声明与实际提供服务和阿里云账户条款一致。
