---
name: model-disaster-recovery
description: Detect cloud model failures and automatically switch to local models for OpenClaw. Use when cloud model times out, returns errors, or user asks about "disaster recovery", "failover", "model fallback", "switch to local model", or "check DR status". Also use when starting OpenClaw to verify backup model availability.
---

# Model Disaster Recovery v5

Automatically detect cloud model failures, switch to local models, and recover when cloud is back.

## v5 核心改进

| 问题 | v4 | v5 |
|------|----|----|
| log 输出污染 | stdout 污染返回值 | stderr 独立输出 |
| 云端失败策略 | 尝试所有云端模型 | **立即切换本地** |
| 配置写入验证 | 无 | 写入后验证正确性 |
| 状态文件验证 | 无 | jq 解析失败时重建 |

## ⚠️ 重要：模型切换必须验证

**永远不要切换到不存在的模型！**

切换前必须验证：
1. 模型是否在允许列表中
2. 本地模型是否存在于 ollama
3. 模型是否真的能用（发送测试请求）

**允许的模型：**
| 类型 | 模型名 |
|------|--------|
| 云端主力 | `ollama/glm-5:cloud` |
| 云端大模型 | `ollama/qwen3.5:397b-cloud` |
| 云端创意 | `ollama/minimax-m2.5:cloud` |
| 本地主力 | `ollama/qwen3.5-27b-dr` |
| 本地轻量 | `ollama/qwen2.5-7b-dr` |
| 本地备用 | `ollama/qwen3.5:9b` |

**"mini" 不是有效模型名！**

## Quick Start

```bash
# Check DR status
./model-disaster-recovery.sh status

# Run failover check (for cron)
./model-disaster-recovery.sh check

# Startup check (run on boot)
./model-disaster-recovery.sh startup
```

## Configuration

Edit `~/.openclaw/dr-config.json`:

```json
{
  "cloudModels": ["glm-5:cloud", "minimax-m2.5:cloud", "qwen3.5:397b-cloud"],
  "localModels": {
    "primary": "qwen3.5-27b-dr",
    "wakeup": "qwen2.5-7b-dr",
    "backup": "qwen3.5:9b"
  },
  "timeout": 30,
  "checkInterval": 180,
  "autoPull": true
}
```

**切换优先级**：
```
云端失败 → 本地主模型 → 轻量模型 → 备用模型 → 云端（最后）
```

## Examples

**Example 1: Cloud timeout**
User says: "云端模型超时了"
Actions:
1. Script detects cloud unresponsive (30s timeout)
2. **立即切换本地，不尝试其他云端**
3. Updates OpenClaw config and restarts gateway
4. Logs state to `~/.openclaw/logs/dr-state.json`
Result: Running on local model, cloud recovery pending

**Example 2: Manual status check**
User says: "检查灾备状态"
Actions:
1. Run `./model-disaster-recovery.sh status`
2. Display current mode, cloud status, local model availability
Result: Status report with all model states

**Example 3: Cloud recovery**
User says: "云端恢复了吗"
Actions:
1. Script checks cloud availability
2. If available, restores original config
3. Restarts gateway
4. Updates state file
Result: Back on cloud model

## Workflow

### Automatic Failover (v5 策略)

```
1. Cron 每 3 分钟检查
2. 当前模型失败 → 立即切换本地主模型
3. 主模型失败 → 尝试轻量模型
4. 轻量失败 → 尝试备用模型
5. 全部失败 → 尝试云端（最后手段）
```

### Manual Commands

| Command | Purpose |
|---------|---------|
| `startup` | 启动预检查（检查服务、模型、自动修复） |
| `check` | 定期健康检查 |
| `status` | 显示当前状态 |
| `switch-local` | 强制切换到本地模型 |
| `switch-cloud` | 强制切换到云端模型 |
| `config` | 显示配置 |

## State Files

| File | Purpose |
|------|---------|
| `~/.openclaw/dr-config.json` | User configuration |
| `~/.openclaw/logs/dr-state.json` | Current state |
| `~/.openclaw/logs/disaster-recovery.log` | Action logs |

## Cron Setup

```bash
# Every 3 minutes
*/3 * * * * ~/.openclaw/scripts/model-disaster-recovery.sh check >> ~/.openclaw/logs/disaster-recovery.log 2>&1
```

## Troubleshooting

**Error: "配置验证失败"**
Cause: 配置写入时被污染（v4 bug）
Solution:
```bash
# 手动修复配置
jq '.agents.defaults.model.primary = "ollama/glm-5:cloud"' ~/.openclaw/openclaw.json > /tmp/fix.json
mv /tmp/fix.json ~/.openclaw/openclaw.json
```

**Error: "没有本地模型可用"**
Cause: No local models installed in Ollama
Solution:
1. Install models: `ollama pull qwen3.5-27b-dr`
2. Verify: `ollama list`

**Error: "Gateway 重启失败"**
Cause: Gateway process not running or permissions issue
Solution:
1. Check gateway: `ps aux | grep openclaw-gateway`
2. Restart manually: `openclaw gateway restart`

**Cloud still slow after recovery**
Cause: Cloud model still having issues
Solution:
1. Check cloud latency: `./model-disaster-recovery.sh status`
2. Consider staying on local if cloud is unreliable

## v5 技术细节

### stdout/stderr 分离

```bash
# v4 (错误)
log() {
    echo "$1"      # 污染 stdout，导致返回值包含日志
}

# v5 (正确)
log() {
    echo "$1" >&2  # 输出到 stderr，不污染返回值
}
```

### 配置写入验证

```bash
write_model_config() {
    # 写入
    jq --arg model "$model" '.agents.defaults.model.primary = $model' "$CONFIG_FILE"

    # 验证
    local written=$(jq -r '.agents.defaults.model.primary' "$CONFIG_FILE")
    if [ "$written" != "$model" ]; then
        # 恢复备份
        mv "${CONFIG_FILE}.dr-backup" "$CONFIG_FILE"
        return 1
    fi
}
```

### 快速失败策略

```bash
find_available_model() {
    # 1. 当前模型失败 → 立即尝试本地
    # 2. 本地主模型失败 → 尝试轻量
    # 3. 轻量失败 → 尝试备用
    # 4. 全部失败 → 尝试云端（最后）
}
```

## Resources

### scripts/

- `model-disaster-recovery.sh` - Main DR script (v5)