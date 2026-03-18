#!/bin/bash
# 模型灾备脚本 v6 - 本地优先（2026-03-18）
# 核心改进：
# 1. 本地模型优先，云端作为扩展能力
# 2. 网络受限时直接使用本地，不浪费时间尝试云端
# 3. MiniMax 已降级（循环问题、Tool calling 错误）
# 4. 本地不可用时才尝试云端

set -e

CONFIG_FILE="$HOME/.openclaw/openclaw.json"
DR_CONFIG="$HOME/.openclaw/dr-config.json"
LOG_FILE="$HOME/.openclaw/logs/disaster-recovery.log"
STATE_FILE="$HOME/.openclaw/logs/dr-state.json"
OLLAMA_URL="http://127.0.0.1:11434"

DEFAULT_CONFIG='{
  "cloudModels": ["glm-5:cloud", "qwen3.5:397b-cloud"],
  "localModels": {
    "primary": "qwen3.5:9b",
    "backup": "qwen3.5:9b"
  },
  "timeout": 30,
  "checkInterval": 180,
  "autoPull": true,
  "requireToolSupport": true
}'

# === 日志函数（输出到 stderr，不污染 stdout）===
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    echo "$1" >&2  # 关键：输出到 stderr
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >> "$LOG_FILE"
    echo "❌ $1" >&2
}

log_ok() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] OK: $1" >> "$LOG_FILE"
    echo "✅ $1" >&2
}

# === 配置管理 ===
init_config() {
    if [ ! -f "$DR_CONFIG" ]; then
        mkdir -p "$(dirname "$DR_CONFIG")"
        echo "$DEFAULT_CONFIG" > "$DR_CONFIG"
        log "创建默认配置: $DR_CONFIG"
    fi
}

get_config() {
    init_config
    jq -r "$1" "$DR_CONFIG" 2>/dev/null
}

# === Ollama 服务检查 ===
check_ollama_service() {
    if curl -s --max-time 5 "${OLLAMA_URL}/api/tags" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

start_ollama_service() {
    log "尝试启动 Ollama 服务..."
    
    if pgrep -x "ollama" > /dev/null; then
        return 0
    fi
    
    ollama serve > /dev/null 2>&1 &
    sleep 3
    
    check_ollama_service
}

# === 模型验证 ===
model_exists_locally() {
    local model="$1"
    local model_name="${model#ollama/}"
    
    # 云端模型跳过本地检查
    if [[ "$model_name" == *":cloud"* ]]; then
        return 0
    fi
    
    ollama list 2>/dev/null | grep -q "$model_name"
}

test_model_api() {
    local model="$1"
    local model_name="${model#ollama/}"
    local timeout=$(get_config '.timeout // 30')
    local require_tools=$(get_config '.requireToolSupport // false')
    
    # 如果需要工具支持，用 /api/chat 测试
    if [ "$require_tools" = "true" ]; then
        local response
        response=$(curl -s --max-time "$timeout" "${OLLAMA_URL}/api/chat" \
            -d "{\"model\": \"${model_name}\", \"messages\": [{\"role\": \"user\", \"content\": \"test\"}], \"tools\": [{\"type\": \"function\", \"function\": {\"name\": \"test\"}}], \"stream\": false}" 2>&1)
        
        if echo "$response" | grep -q "error"; then
            log "模型不支持 Tool Calling: $model_name" >&2
            return 1
        fi
        
        if echo "$response" | grep -q "message"; then
            return 0
        else
            return 1
        fi
    fi
    
    # 默认：只测试文本生成
    local response
    response=$(curl -s --max-time "$timeout" "${OLLAMA_URL}/api/generate" \
        -d "{\"model\": \"${model_name}\", \"prompt\": \"hi\", \"stream\": false}" 2>&1)
    
    if echo "$response" | grep -q "response"; then
        return 0
    else
        return 1
    fi
}

# === 配置写入（带验证）===
write_model_config() {
    local model="$1"
    
    # 验证模型名格式（必须包含 /）
    if [[ ! "$model" =~ ^ollama/ ]]; then
        log_error "Invalid model format: $model"
        return 1
    fi
    
    # 备份
    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" "${CONFIG_FILE}.dr-backup"
    fi
    
    # 使用 jq 写入（确保单行、无污染）
    if jq --arg model "$model" \
        '.agents.defaults.model.primary = $model' \
        "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"; then
        mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        
        # 验证写入结果
        local written=$(jq -r '.agents.defaults.model.primary' "$CONFIG_FILE" 2>/dev/null)
        if [ "$written" = "$model" ]; then
            log_ok "配置已更新: $model"
            return 0
        else
            log_error "配置验证失败: 期望 $model, 实际 $written"
            # 恢复备份
            [ -f "${CONFIG_FILE}.dr-backup" ] && mv "${CONFIG_FILE}.dr-backup" "$CONFIG_FILE"
            return 1
        fi
    else
        log_error "jq 写入失败"
        return 1
    fi
}

# === 核心逻辑：云端失败 → 立即切换本地 ===
try_cloud_model() {
    local model="$1"
    local model_name="${model#ollama/}"
    
    log "测试云端模型: $model_name"
    
    if test_model_api "$model"; then
        log_ok "云端模型可用: $model_name"
        return 0
    else
        log "云端模型不可用: $model_name" >&2
        return 1
    fi
}

try_local_model() {
    local model="$1"
    local model_name="${model#ollama/}"
    
    log "测试本地模型: $model_name"
    
    # 检查是否存在
    if ! model_exists_locally "$model"; then
        local auto_pull=$(get_config '.autoPull // true')
        if [ "$auto_pull" = "true" ]; then
            log "拉取本地模型: $model_name"
            if ollama pull "$model_name" > /dev/null 2>&1; then
                log_ok "拉取成功: $model_name"
            else
                log "拉取失败: $model_name" >&2
                return 1
            fi
        else
            log "模型不存在: $model_name" >&2
            return 1
        fi
    fi
    
    if test_model_api "$model"; then
        log_ok "本地模型可用: $model_name"
        return 0
    else
        log "本地模型不可用: $model_name" >&2
        return 1
    fi
}

# === 主逻辑 ===
switch_to_model() {
    local model="$1"
    local mode="$2"  # cloud, local, auto
    
    log "切换到模型: $model ($mode)"
    
    if write_model_config "$model"; then
        # 更新状态
        echo "{\"mode\": \"${mode}\", \"since\": \"$(date -Iseconds)\", \"model\": \"${model#ollama/}\"}" > "$STATE_FILE"
        
        # 重启 gateway
        if pgrep -f openclaw-gateway > /dev/null; then
            pkill -f openclaw-gateway
            sleep 2
        fi
        
        log_ok "已切换到 ${mode} 模式: ${model#ollama/}"
        return 0
    else
        return 1
    fi
}

# === 本地优先：本地 → 云端 ===
find_available_model() {
    local primary=$(jq -r '.agents.defaults.model.primary // empty' "$CONFIG_FILE" 2>/dev/null)
    local local_primary=$(get_config '.localModels.primary')
    local local_wakeup=$(get_config '.localModels.wakeup')
    local local_backup=$(get_config '.localModels.backup')
    local cloud_models=$(get_config '.cloudModels | @sh' | tr -d "'")
    
    log "=== 开始查找可用模型（本地优先）==="
    
    # 1. 本地主模型（最高优先级）
    log "1. 尝试本地主模型: $local_primary"
    if try_local_model "ollama/$local_primary"; then
        switch_to_model "ollama/$local_primary" "local"
        return $?
    fi
    
    # 2. 本地轻量模型
    log "2. 尝试本地轻量模型: $local_wakeup"
    if try_local_model "ollama/$local_wakeup"; then
        switch_to_model "ollama/$local_wakeup" "local"
        return $?
    fi
    
    # 3. 本地备用模型
    log "3. 尝试本地备用模型: $local_backup"
    if try_local_model "ollama/$local_backup"; then
        switch_to_model "ollama/$local_backup" "local"
        return $?
    fi
    
    # 4. 所有本地模型失败，尝试云端（作为最后手段）
    log "4. 所有本地模型失败，尝试云端（网络可能受限）..."
    
    for cloud_model in $cloud_models; do
        log "尝试云端模型: $cloud_model"
        if test_model_api "ollama/$cloud_model"; then
            switch_to_model "ollama/$cloud_model" "cloud"
            return $?
        fi
    done
    
    log_error "没有可用模型！请确保至少有一个本地模型已安装"
    log "建议：ollama pull qwen3.5-27b-dr"
    return 1
}

# === 定期检查 ===
health_check() {
    log "=== 灾备健康检查 ==="
    
    # 1. 检查 Ollama 服务
    if ! check_ollama_service; then
        log "Ollama 服务未运行，尝试启动..."
        if ! start_ollama_service; then
            log_error "无法启动 Ollama 服务"
            return 1
        fi
    fi
    
    # 2. 获取当前状态
    local current=$(jq -r '.agents.defaults.model.primary // empty' "$CONFIG_FILE" 2>/dev/null)
    local mode=$(jq -r '.mode // "unknown"' "$STATE_FILE" 2>/dev/null)
    
    if [ -z "$current" ] || [ "$current" = "null" ]; then
        log "没有配置模型，查找可用..."
        find_available_model
        return $?
    fi
    
    # 3. 测试当前模型
    if test_model_api "$current"; then
        log_ok "当前模型可用: $current"
        
        # 4. 如果在本地模式，检查云端是否恢复
        if [ "$mode" = "local" ]; then
            local cloud_primary=$(get_config '.cloudModels[0]')
            log "检查云端恢复状态..."
            if test_model_api "ollama/$cloud_primary"; then
                log_ok "云端已恢复，考虑切回..."
                # 可选：自动切回云端（当前策略：保持本地）
                # switch_to_model "ollama/$cloud_primary" "cloud"
            fi
        fi
        return 0
    fi
    
    # 5. 当前模型失败 → 查找替代
    log "当前模型失败: $current"
    find_available_model
}

# === 启动时预检查 ===
startup_check() {
    log "=== 启动预检查 ==="
    
    # 检查 Ollama 服务
    if ! check_ollama_service; then
        log "Ollama 服务未运行，尝试启动..."
        if ! start_ollama_service; then
            log_error "无法启动 Ollama 服务"
            log "请确保 Ollama 已安装: curl -fsSL https://ollama.com/install.sh | sh"
            return 1
        fi
    fi
    
    # 检查配置
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "配置文件不存在: $CONFIG_FILE"
        return 1
    fi
    
    # 运行健康检查
    health_check
}

# === 状态显示 ===
show_status() {
    echo "=== 灾备状态 ===" >&2
    echo "" >&2
    
    echo "当前模式:" >&2
    if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE" | jq . >&2
    else
        echo '{"mode": "unknown"}' | jq . >&2
    fi
    
    echo "" >&2
    echo "当前配置模型:" >&2
    jq -r '.agents.defaults.model.primary // "未配置"' "$CONFIG_FILE" 2>/dev/null >&2
    
    echo "" >&2
    echo "云端模型列表:" >&2
    get_config '.cloudModels[]' | while read m; do echo "  - $m" >&2; done
    
    echo "" >&2
    echo "本地模型:" >&2
    echo "  主模型: $(get_config '.localModels.primary')" >&2
    echo "  轻量: $(get_config '.localModels.wakeup')" >&2
    echo "  备用: $(get_config '.localModels.backup')" >&2
    
    echo "" >&2
    echo "Ollama 已安装模型:" >&2
    ollama list 2>/dev/null | tail -n +2 | while read line; do echo "  $line" >&2; done
}

# === 强制切换 ===
switch_to_local() {
    local local_primary=$(get_config '.localModels.primary')
    
    if try_local_model "ollama/$local_primary"; then
        switch_to_model "ollama/$local_primary" "local"
    else
        log_error "本地模型不可用"
        return 1
    fi
}

switch_to_cloud() {
    local cloud_primary=$(get_config '.cloudModels[0]')
    
    if try_cloud_model "ollama/$cloud_primary"; then
        switch_to_model "ollama/$cloud_primary" "cloud"
    else
        log_error "云端模型不可用"
        return 1
    fi
}

# === 命令分发 ===
show_help() {
    echo "用法: $0 <command>" >&2
    echo "" >&2
    echo "命令:" >&2
    echo "  startup         启动预检查（检查服务、模型、自动修复）" >&2
    echo "  check           定期健康检查" >&2
    echo "  status          显示当前状态" >&2
    echo "  switch-local    强制切换到本地模型" >&2
    echo "  switch-cloud    强制切换到云端模型" >&2
    echo "  config          显示配置" >&2
    echo "  help            显示帮助" >&2
}

case "${1:-status}" in
    startup)
        startup_check
        ;;
    check)
        health_check
        ;;
    status)
        show_status
        ;;
    switch-local)
        switch_to_local
        ;;
    switch-cloud)
        switch_to_cloud
        ;;
    config)
        init_config
        echo "配置文件: $DR_CONFIG" >&2
        cat "$DR_CONFIG" | jq . >&2
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "未知命令: $1" >&2
        show_help
        exit 1
        ;;
esac