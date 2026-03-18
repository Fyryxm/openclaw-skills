# Model Disaster Recovery v7

OpenClaw 灾备系统 - 自动检测云端模型故障并切换到本地模型。

## v7 核心改进

- **Tool Calling 支持**：只切换到支持工具调用的模型
- **智能检测**：使用 `/api/chat` + tools 参数测试
- **安全优先**：避免切换到不支持 Tools 的模型导致 Agent 失效

## 支持的本地模型

| 模型 | 大小 | Tool Calling |
|------|------|--------------|
| qwen3.5:9b | 6.6GB | ✅ |
| llama3.1:8b | 4.7GB | ✅ |

## 不支持的模型

| 模型 | 原因 |
|------|------|
| qwen3.5-27b-dr | 微调版，不支持 Tools |
| qwen2.5-7b-dr | 微调版，不支持 Tools |

## 使用

```bash
# Cron 每 3 分钟检查
*/3 * * * * ~/.openclaw/scripts/model-disaster-recovery.sh check

# 手动检查
./model-disaster-recovery.sh status
```
