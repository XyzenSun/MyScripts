#!/bin/bash

# ==============================================================================
# Docker 全局日志配置脚本
#
# 功能:
# 1. 自动配置 Docker 的 daemon.json 文件，以限制全局日志大小和数量。
# 2. 安全地修改现有配置（需要 jq 工具）。
# 3. 重启 Docker 服务使配置生效。
# ==============================================================================

# --- 配置颜色输出 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- 函数定义 ---
log_info() { echo -e "${BLUE}[INFO] $1${NC}"; }
log_success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }
log_warning() { echo -e "${YELLOW}[WARNING] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; }

# --- 脚本主要逻辑 ---

# 检查是否以 root 身份运行
if [ "$(id -u)" -ne 0 ]; then
   log_error "此脚本必须以 root 用户身份运行。请使用 'sudo ./configure_docker_logs.sh' 执行。"
   exit 1
fi

# 检查 Docker 是否已安装
if ! command -v docker &> /dev/null; then
    log_error "未检测到 Docker。请先安装 Docker 再运行此脚本。"
    exit 1
fi

DAEMON_JSON_FILE="/etc/docker/daemon.json"
MAX_SIZE="100m"
MAX_FILE="3"

# 配置内容
LOG_CONFIG_JSON=$(cat <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "$MAX_SIZE",
    "max-file": "$MAX_FILE"
  }
}
EOF
)

# 确保 /etc/docker 目录存在
mkdir -p /etc/docker

log_info "开始配置 Docker 全局日志..."
log_info "目标配置: max-size=${MAX_SIZE}, max-file=${MAX_FILE}"

if [ -f "$DAEMON_JSON_FILE" ]; then
    log_info "检测到已存在的配置文件: $DAEMON_JSON_FILE"
    
    # 检查 jq 是否安装
    if ! command -v jq &> /dev/null; then
        log_warning "为了安全地修改 JSON 文件，建议安装 'jq' 工具。"
        read -p "是否现在尝试自动安装 jq? (y/n): " install_jq
        if [[ "$install_jq" == "y" || "$install_jq" == "Y" ]]; then
            apt-get update >/dev/null && apt-get install -y jq
            if [ $? -ne 0 ]; then
                log_error "jq 安装失败。请手动安装后重新运行脚本。例如: sudo apt-get install jq"
                exit 1
            fi
            log_success "jq 安装成功。"
        else
            log_error "脚本中止。请安装 jq 或手动修改 $DAEMON_JSON_FILE 文件。"
            exit 1
        fi
    fi

    log_info "使用 jq 安全地更新配置文件..."
    # 使用 jq 将新的日志配置合并到现有文件中
    TEMP_FILE=$(mktemp)
    jq \
    --arg driver "json-file" \
    --arg size "$MAX_SIZE" \
    --argjson file "$MAX_FILE" \
    '.["log-driver"] = $driver | .["log-opts"] = {"max-size": $size, "max-file": $file}' \
    "$DAEMON_JSON_FILE" > "$TEMP_FILE"

    # 检查jq操作是否成功
    if [ $? -eq 0 ] && [ -s "$TEMP_FILE" ]; then
        mv "$TEMP_FILE" "$DAEMON_JSON_FILE"
        log_success "配置文件更新成功。"
    else
        log_error "使用 jq 更新配置文件失败！请检查 $DAEMON_JSON_FILE 的格式是否为有效的 JSON。"
        rm -f "$TEMP_FILE"
        exit 1
    fi

else
    log_info "未找到配置文件，将创建新的 $DAEMON_JSON_FILE。"
    echo "$LOG_CONFIG_JSON" > "$DAEMON_JSON_FILE"
    log_success "配置文件创建成功。"
fi

echo -e "\n--- 更新后的配置文件内容 ---"
cat "$DAEMON_JSON_FILE"
echo -e "----------------------------\n"

log_info "正在重启 Docker 服务以应用配置..."
systemctl restart docker
if [ $? -ne 0 ]; then
    log_error "Docker 服务重启失败！请手动检查 'sudo systemctl status docker' 或 'sudo journalctl -xeu docker.service' 获取错误信息。"
    exit 1
fi
log_success "Docker 服务已成功重启。"

exit 0
