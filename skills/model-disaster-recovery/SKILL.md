---
name: model-disaster-recovery
description: Detect cloud model failures and automatically switch to local models for OpenClaw. Use when cloud model times out, returns errors, or user asks about "disaster recovery", "failover", "model fallback", "switch to local model", or "check DR status". Also use when starting OpenClaw to verify backup model availability.
---

# Model Disaster Recovery v7

Automatically detect cloud model failures, switch to local models with Tool Calling support, and recover when cloud is back.

## v7 核心改进

| 问题 | v6 | v7 |
|------|----|----|
| 本地模型不支持 Tools | 切换后报错 | **只选择支持 Tools 的模型** |
| 模型验证 | 只测试文本生成 | **测试 Tool Calling 支持** |
| 本地模型列表 | 27B/7B/9B 混合 | **9B (支持 tools) + llama3.1 备用** |

## ⚠️ 重要：Tool Calling 支持检测

**OpenClaw Agent 需要 Tool Calling！**

v6 的问题：切换到不支持 Tools 的本地模型后，Agent 无法调用工具。

v7 解决方案：
1. `requireToolSupport: true` 配置项
2. 测试时用 `/api/chat` + tools 参数
3. 只切换到支持 Tools 的模型

**支持 Tool Calling 的模型：**
| 模型 | 大小 | Tools | 状态 |
|------|------|-------|------|
| `qwen3.5:9b` | 6.6GB | ✅ | 灾备首选 |
| `llama3.1:8b` | 4.7GB | ✅ | 灾备备用 |
| `mistral:7b` | 4.1GB | ✅ | 可选 |

**不支持 Tools 的模型（不要用于灾备）：**
| 模型 | 大小 | 原因 |
|------|------|------|
| `qwen3.5-27b-dr` | 11GB | 微调版，不支持 |
| `qwen2.5-7b-dr` | 3.8GB | 微调版，不支持 |
| `qwen2-7b-instruct` | 4.7GB | 旧版，不支持 |

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
  "cloudModels": ["glm-5:cloud", "qwen3.5:397b-cloud"],
  "localModels": {
    "primary": "qwen3.5:9b",
    "backup": "llama3.1:8b"
  },
  "timeout": 30,
  "checkInterval": 180,
  "autoPull": true,
  "requireToolSupport": true
}
```

**配置说明：**
- `requireToolSupport`: `true` = 只切换到支持 Tools 的模型
- `cloudModels`: 移除了 `minimax-m2.5:cloud`（循环问题）
- `localModels.primary`: `qwen3.5:9b` 支持工具调用

**切换优先级：**
```
云端失败 → 本地 qwen3.5:9b → 本地 llama3.1:8b → 云端（最后）
```

## Tool Calling 检测原理

```bash
# v6 (错误) - 只测试文本生成
curl /api/generate -d '{"model": "xxx", "prompt": "hi"}'

# v7 (正确) - 测试工具调用支持
curl /api/chat -d '{
  "model": "xxx",
  "messages": [{"role": "user", "content": "test"}],
  "tools": [{"type": "function", "function": {"name": "test"}}]
}'

# 如果返回 error: "does not support tools" → 跳过该模型
```

## Examples

**Example 1: Cloud timeout**
User says: "云端模型超时了"
Actions:
1. Script detects cloud unresponsive (30s timeout)
2. 测试本地模型的 Tool Calling 支持
3. 切换到 `qwen3.5:9b`（支持 tools）
4. Updates OpenClaw config and restarts gateway
Result: Running on local model with full tool support

**Example 2: All local models failed tools test**
User says: "检查灾备状态"
Actions:
1. `qwen3.5:9b` 测试失败
2. `llama3.1:8b` 测试失败
3. 报错 "No local model supports Tool Calling"
4. 建议：`ollama pull qwen3.5:9b` 或保持云端
Result: Clear error message with solution

## Workflow

### Automatic Failover (v7 策略)

```
1. Cron 每 3 分钟检查
2. 当前模型失败 → 测试本地模型 Tool Calling
3. 找到支持 Tools 的本地模型 → 切换
4. 找不到 → 尝试云端（网络可能恢复）
5. 全部失败 → 保持当前配置，报错
```

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

**Error: "does not support tools"**
Cause: 本地模型不支持 Tool Calling
Solution:
```bash
# 拉取支持 tools 的模型
ollama pull qwen3.5:9b
ollama pull llama3.1:8b

# 验证
ollama list | grep -E "qwen3.5:9b|llama3.1"
```

**Error: "No local model supports Tool Calling"**
Cause: 所有本地模型都不支持 Tools
Solution:
1. 保持云端模型
2. 检查网络
3. 或拉取支持 Tools 的模型

**配置验证失败**
Cause: 配置写入时被污染
Solution:
```bash
# 手动修复
jq '.agents.defaults.model.primary = "ollama/glm-5:cloud"' ~/.openclaw/openclaw.json > /tmp/fix.json
mv /tmp/fix.json ~/.openclaw/openclaw.json
```

## Changelog

### v7 (2026-03-18)
- 新增 `requireToolSupport` 配置项
- 测试时使用 `/api/chat` + tools 参数
- 本地模型列表更新：移除不支持 Tools 的模型
- 云端模型列表：移除 MiniMax（循环问题）

### v6 (2026-03-18)
- 本地优先策略
- 云端失败立即切换本地

### v5 (2026-03-18)
- log() 输出到 stderr
- 配置写入验证
- 状态文件验证

## Resources

### scripts/

- `model-disaster-recovery.sh` - Main DR script (v7)