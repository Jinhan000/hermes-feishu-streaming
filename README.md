# Feishu Card Kit Streaming: 飞书逐字流式输出

> 在 Hermes Agent 的飞书消息中实现类似 ChatGPT 的逐字显示效果。
> **非官方功能**——通过 Card Kit API 的 `streaming_mode` 特性实现，代码修改自 feishu.py。

---

## 效果

当你发送一条长回复时，飞书消息会像打字机一样逐字显示，而不是一次性显示全部内容。相比传统模式（等待 → 突然出现），流式输出的体验更像实时对话。

---

## 原理

Hermes Gateway 的标准 token streaming 机制（`edit_message` 轮询）仅适用于支持 `editMessageText` 的平台（Telegram）。飞书的消息发送后不可编辑，要走 Card Kit API：

```
消息生成 → Card Kit 创建 streaming card → 逐段 PUT 更新元素内容
       → 最后 PATCH settings 关闭 streaming_mode → 转为静态卡片
```

| 阶段 | 操作 | API |
|------|------|-----|
| 创建 | `POST /cardkit/v1/cards` (带 `streaming_mode: true`) | Card Kit API |
| 更新 | `PUT /cardkit/v1/cards/{id}/elements/content/content` | Card Kit API |
| 关闭 | `PATCH /cardkit/v1/cards/{id}/settings` (关闭 `streaming_mode`) | Card Kit API |

---

## 配置

### 1. 配置 config.yaml

```yaml
# ── 飞书流式输出 ──
feishu:
  streaming: true

# ── 全局 streaming 配置 ──
streaming:
  enabled: true           # 启用 token streaming（Hermes 内部）
  edit_interval: 0.6      # 编辑间隔（秒），调小 = 更快但更耗 API
  buffer_threshold: 25    # 累积多少字符触发一次更新

# ── 关闭回答尾巴 ──
display:
  runtime_footer:
    enabled: false         # 关掉每次回复后的 "model | context%" 尾巴
```

**字段说明：**

| 字段 | 默认值 | 说明 |
|------|--------|------|
| `feishu.streaming` | `false` | 飞书 Card Kit 流式开关 |
| `streaming.enabled` | `false` | Hermes 内部 streaming 引擎开关 |
| `streaming.edit_interval` | `1.0` | 两次编辑之间至少等几秒。调小到 `0.6` 更流畅，但留意飞书 API 限速 |
| `streaming.buffer_threshold` | `40` | 累积的字符数达到此值才触发一次更新。调小 = 更新更频繁（更接近实时），调大 = 减少 API 调用 |
| `display.runtime_footer.enabled` | `true` | 流式输出最后会多一行 `model | 20%`，建议关掉 |

### 2. 可选：通过环境变量配置

如果不想改 config.yaml，也可以设环境变量：

```bash
export FEISHU_STREAMING=true
```

但推荐 config.yaml 方式，更持久。

### 3. 重启 Gateway

```bash
hermes gateway restart
# 或如果前台运行
hermes gateway run --replace
```

---

## 调参指南

流式输出的体验取决于三个参数配合：

| 参数 | 调小 → | 调大 → |
|------|--------|--------|
| `edit_interval` | 更新更频繁，更流畅但更耗 API | 更新稀疏，字符块跳跃出现 |
| `buffer_threshold` | 更接近逐字，API 调用更多 | 字符块变大，更新次数减少 |
| `print_step` (见下方) | 每次 Reveal 字符更少，动画更细腻 | 每次 Reveal 字符更多，更新更跳跃 |

**推荐组合：**

- **流畅优先**：`edit_interval: 0.6`, `buffer_threshold: 15`, `print_step: 2`
- **均衡**（默认）：`edit_interval: 0.6`, `buffer_threshold: 25`, `print_step: 4`
- **API 节省**：`edit_interval: 1.5`, `buffer_threshold: 50`, `print_step: 6`

`print_step` 是 Card Kit 侧参数，在 feishu.py 代码中硬编码，调整需改源码（`streaming_config.print_step.default`）。后续脚本可代为修改。

---

## 部署脚本

配套脚本 `feishu-streaming-setup.sh` 可一键完成：

1. 在 config.yaml 中启用/禁用飞书流式
2. 调整 streaming 参数（edit_interval / buffer_threshold）
3. 检查当前配置状态
4. 重启 Gateway

```bash
# 启用流式（均衡模式）
bash ~/.hermes/scripts/feishu-streaming-setup.sh enable

# 启用并调参
bash ~/.hermes/scripts/feishu-streaming-setup.sh enable --edit-interval 0.4 --buffer-threshold 15

# 禁用流式
bash ~/.hermes/scripts/feishu-streaming-setup.sh disable

# 查看状态
bash ~/.hermes/scripts/feishu-streaming-setup.sh status
```

---

## 故障排查

### 流式没有生效，仍然是瞬间出现
- 确认 `feishu.streaming: true` 在 config.yaml 中
- 确认 gateway 已重启
- 查看 gateway log：`grep -i "streaming" ~/.hermes/logs/gateway.log`
- 正常启动应有：`[Feishu] Streaming card created: card_id=xxx`

### 「Card Kit」错误日志
- 检查飞书应用是否有 `cardkit:card` 权限
- 需要在飞书开放平台 → 应用 → 权限管理 → 添加「卡片」(cardkit) 权限
- Token 刷新失败：检查 `FEISHU_APP_ID` / `FEISHU_APP_SECRET` 是否正确

### 流式更新卡住，消息不再变化
- 通常在消息结束时恢复正常（finalize 机制会在超时后关闭）
- 检查是否有 `[Feishu] Update streaming card failed` 日志
- 可能是飞书 API 限速，调大 `edit_interval`

---

## 已知限制

| 限制 | 说明 |
|------|------|
| 仅限飞书平台 | 其他平台（Discord/Telegram）有自己的流式机制 |
| 卡片形式发送 | 流式输出走的是 Card Kit 交互卡片，不是普通 text 消息 |
| 无原生光标 | Card Kit 没有 Telegram 那样的打字光标，只是卡片内容在变化 |
| 最终 summary | 卡片关闭后显示的 summary 是内容的前 50 字符 |
| API 配额 | Card Kit API 有速率限制，频繁更新可能被限 |

---

## 代码逻辑概要（供后续维护参考）

如果未来 Hermes 官方更新了 feishu.py，核心修改点：

| 位置 | 改动 |
|------|------|
| `FeishuAdapterSettings` | 新增 `streaming: bool = False` 字段 |
| `FeishuAdapter.__init__` | 新增 `_streaming_sessions` 字典和 `_cardkit_token` 缓存 |
| `FeishuAdapter._load_settings` | 从 `extra` 读取 `streaming` 字段 |
| `FeishuAdapter.send()` | 当 `streaming=True` 时走 `_create_streaming_card` |
| `FeishuAdapter.edit_message()` | 检查 `_streaming_sessions` 走更新流程 |
| `FeishuAdapter._cardkit_base_url()` | 根据 `_domain_name` 返回正确 base URL |
| `FeishuAdapter._cardkit_refresh_token()` | 用 app_id/app_secret 获取 tenant_access_token |
| `FeishuAdapter._create_streaming_card()` | 创建 card + 发送的完整流程 |
| `FeishuAdapter._update_streaming_card()` | 更新 card 元素的增量逻辑 |
| `FeishuAdapter._close_streaming_card()` | 关闭 streaming_mode 转为静态卡片 |
| `gateway/config.py` | 新增 `feishu: streaming: true` → `FEISHU_STREAMING` env var 桥接 |
