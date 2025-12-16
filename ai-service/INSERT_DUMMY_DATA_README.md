# 插入模拟分析数据 (Insert Dummy Analytics Data)

这个脚本可以帮助你向 Firebase Realtime Database 插入模拟的分析数据，用于测试 CrowdSense 应用的 Analytics 功能。

## 安装依赖

```bash
cd ai-service
pip install -r requirements.txt
```

或者只安装必要的库：

```bash
pip install requests firebase-admin
```

## 使用方法

### 方法 1: 使用 REST API (推荐，最简单)

```bash
python insert_dummy_analytics.py --zone-id <你的ZONE_ID>
```

**示例：**
```bash
# 插入过去7天的数据，每5分钟一个数据点（默认设置）
python insert_dummy_analytics.py --zone-id "-OezNg4CUBhVTFZ2iL8l"

# 插入过去30天的数据，每10分钟一个数据点
python insert_dummy_analytics.py --zone-id "-OezNg4CUBhVTFZ2iL8l" --days 30 --interval-minutes 10

# 自定义人数范围和日期范围
python insert_dummy_analytics.py --zone-id "-OezNg4CUBhVTFZ2iL8l" --min-count 10 --max-count 100 --start-date 2024-01-01

# 快速测试：插入过去1天的数据，每15分钟一个数据点
python insert_dummy_analytics.py --zone-id "-OezNg4CUBhVTFZ2iL8l" --days 1 --interval-minutes 15
```

### 方法 2: 使用 Firebase Admin SDK (需要服务账户)

如果你有 Firebase 服务账户 JSON 文件：

```bash
python insert_dummy_analytics.py --zone-id <你的ZONE_ID> --method admin --service-account path/to/serviceAccountKey.json
```

## 参数说明

- `--zone-id` (必需): 要插入数据的 Zone ID
- `--days`: 生成多少天的数据 (默认: 7)
- `--interval-minutes`: 数据点之间的间隔（分钟）(默认: 5)
- `--min-count`: 最小人数 (默认: 0)
- `--max-count`: 最大人数 (默认: 150)
- `--method`: 使用的方法 - 'admin' 或 'rest' (默认: 'rest')
- `--database-secret`: REST API 的数据库密钥（可选）
- `--service-account`: Firebase 服务账户 JSON 文件路径（用于 admin 方法）
- `--start-date`: 开始日期，格式 YYYY-MM-DD (默认: 今天减去天数)

## 如何获取 Zone ID

1. 打开你的 Flutter 应用
2. 进入 Analytics 页面
3. 查看 URL 或应用日志中的 Zone ID
4. 或者查看 Firebase Console > Realtime Database > zones 节点

## 数据模式

脚本会生成符合真实场景的数据：
- **早晨高峰** (8-10点): 40-80 人
- **午餐高峰** (12-14点): 50-90 人
- **傍晚高峰** (17-19点): 60-100 人
- **深夜/凌晨** (22-6点): 0-20 人
- **周末**: 人数会增加约30%
- **其他时间**: 20-60 人

## 故障排除

### REST API 方法返回 401/403 错误

1. 检查 Firebase 数据库规则是否允许写入
2. 获取数据库密钥：
   - 打开 Firebase Console
   - 项目设置 > 服务账户
   - 点击 "数据库密钥"
   - 使用 `--database-secret` 参数

### Admin SDK 方法报错

1. 确保已安装 `firebase-admin`: `pip install firebase-admin`
2. 下载服务账户 JSON 文件：
   - Firebase Console > 项目设置 > 服务账户
   - 点击 "生成新的私钥"
   - 使用 `--service-account` 参数指向该文件

### 找不到 Zone ID

确保 Zone ID 是正确的。可以在 Firebase Console 的 Realtime Database 中查看 `zones` 节点下的所有 Zone ID。

## 示例输出

```
📊 Generating dummy analytics data...
   Zone ID: -OezNg4CUBhVTFZ2iL8l
   Period: 2024-01-15 to 2024-01-22
   Interval: 5 minutes
   Count range: 0 - 150
✅ Generated 2016 data points
📤 Inserting 2016 data points using REST API...
   URL: https://crowdsense-caf2e-default-rtdb.asia-southeast1.firebasedatabase.app/analytics/-OezNg4CUBhVTFZ2iL8l/counts
   Progress: 50/2016
   Progress: 100/2016
   ...
✅ Successfully inserted 2016 data points! (failed: 0)
```

## 注意事项

- 插入大量数据可能需要一些时间
- 确保 Firebase 数据库规则允许写入 `analytics` 节点
- 建议先在测试环境中使用
- 数据会追加到现有数据中，不会覆盖

