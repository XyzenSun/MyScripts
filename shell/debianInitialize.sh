#!/bin/bash

# ==============================================================================
# 服务器初始化交互式脚本 (v3.2 - Root执行版，保留手动SSH配置)
# 功能:
# 1. 更新系统并安装 ufw, curl, wget, fail2ban
# 2. 交互式设置防火墙和Fail2Ban要保护的SSH端口 (注意: 不会自动修改SSH服务)
# 3. 以最佳实践方式配置 Fail2Ban 和 UFW 防火墙
# 4. 交互式设置时区
# 5. 交互式选择是否创建Swap，并自定义大小
# 6. 交互式选择是否安装Docker，并指定一个用户加入docker组
#
# 使用方法:
# 1. 切换到root用户: su -  或  sudo su -
# 2. 将此脚本上传到服务器
# 3. chmod +x init_server_v3.2.sh
# 4. ./init_server_v3.2.sh
# ==============================================================================

# --- 配置颜色输出 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- 全局变量 ---
SSH_PORT=""
TIMEZONE=""
SWAP_SIZE_GB=""
INSTALL_DOCKER=""
DOCKER_USER=""

# --- 函数定义 ---

# 日志打印函数
log_info() { echo -e "${BLUE}[INFO] $1${NC}"; }
log_success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }
log_warning() { echo -e "${YELLOW}[WARNING] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; }

# 1. 询问SSH端口
ask_ssh_port() {
    DEFAULT_SSH_PORT=22
    while true; do
        read -p "$(echo -e ${YELLOW}"请输入您计划使用的SSH端口 [默认为 ${DEFAULT_SSH_PORT}]: "${NC})" SSH_PORT_INPUT
        SSH_PORT=${SSH_PORT_INPUT:-$DEFAULT_SSH_PORT}
        if [[ "$SSH_PORT" =~ ^[0-9]+$ && "$SSH_PORT" -ge 1 && "$SSH_PORT" -le 65535 ]]; then
            break
        else
            log_error "无效输入！请输入一个1到65535之间的数字。"
        fi
    done
}

# 2. 询问时区
ask_timezone() {
    DEFAULT_TIMEZONE="Asia/Singapore"
    read -p "$(echo -e ${YELLOW}"请输入您的时区 [默认为 ${DEFAULT_TIMEZONE}]: "${NC})" TIMEZONE_INPUT
    TIMEZONE=${TIMEZONE_INPUT:-$DEFAULT_TIMEZONE}
}

# 3. 询问并配置Swap
ask_and_configure_swap() {
    if [ -n "$(swapon --show)" ]; then
        log_info "检测到已存在Swap配置，跳过创建步骤。"
        return
    fi
    read -p "$(echo -e ${YELLOW}"未检测到Swap，是否需要创建Swap交换文件? (y/n) [默认 n]: "${NC})" create_swap_choice
    if [[ "$create_swap_choice" != "y" && "$create_swap_choice" != "Y" ]]; then
        log_info "用户选择不创建Swap。"
        return
    fi
    while true; do
        read -p "$(echo -e ${YELLOW}"请输入需要创建的Swap大小 (单位: GB, 例如: 2): "${NC})" SWAP_SIZE_INPUT
        if [[ "$SWAP_SIZE_INPUT" =~ ^[1-9][0-9]*$ ]]; then
            SWAP_SIZE_GB=$SWAP_SIZE_INPUT
            break
        else
            log_error "无效输入！请输入一个正整数。"
        fi
    done
}

# 4. 询问是否安装Docker
ask_install_docker() {
    read -p "$(echo -e ${YELLOW}"是否需要安装Docker? (y/n) [默认 n]: "${NC})" docker_choice
    if [[ "$docker_choice" == "y" || "$docker_choice" == "Y" ]]; then
        INSTALL_DOCKER="yes"
        while true; do
            read -p "$(echo -e ${YELLOW}"请输入一个需要加入docker组的 [现有] 用户名 (该用户将无需sudo运行docker)，留空则跳过: "${NC})" DOCKER_USER_INPUT
            DOCKER_USER=$DOCKER_USER_INPUT
            if [ -z "$DOCKER_USER" ]; then
                log_warning "您选择不指定用户加入docker组。"
                break
            fi
            if id "$DOCKER_USER" &>/dev/null; then
                break
            else
                log_error "用户 '$DOCKER_USER' 不存在，请重新输入一个已存在的用户名。"
            fi
        done
    else
        INSTALL_DOCKER="no"
    fi
}

# 5. 执行系统更新和软件安装
install_software() {
    log_info "开始更新系统并安装必要软件 (ufw, curl, wget, fail2ban)..."
    apt-get update >/dev/null 2>&1 && apt-get install -y ufw curl wget fail2ban
    if [ $? -ne 0 ]; then
        log_error "软件安装失败，请检查apt源或网络连接。脚本中止。"
        exit 1
    fi
    log_success "基础软件安装完成。"
}

# 6. 配置Fail2Ban 
configure_fail2ban() {
    log_info "配置 Fail2Ban 以保护SSH端口: ${SSH_PORT}..."
    JAIL_DIR="/etc/fail2ban/jail.d"
    JAIL_CONF_FILE="${JAIL_DIR}/sshd.conf"

    mkdir -p ${JAIL_DIR}

    cat > ${JAIL_CONF_FILE} << EOF
[sshd]
enabled = true
port    = ${SSH_PORT}
maxretry = 5
bantime  = 36000
EOF

    systemctl restart fail2ban
    if [ $? -eq 0 ]; then
        log_success "Fail2Ban已配置并重启成功。"
    else
        log_error "Fail2Ban重启失败！请手动检查配置: ${JAIL_CONF_FILE}"
    fi
}

# 7. 配置防火墙 (优化后)
configure_firewall() {
    log_info "配置防火墙(UFW)..."
    # 添加必要的端口
    ufw allow 80/tcp comment 'Allow HTTP' >/dev/null
    ufw allow 443/tcp comment 'Allow HTTPS' >/dev/null
    ufw allow 22/tcp comment 'Allow SSH fallback' >/dev/null # 始终允许22端口，作为安全后备
    log_info "已开放端口: 80 (HTTP), 443 (HTTPS), 22 (SSH后备)。"
      # 3. 如果用户选择了自定义端口，也开放它
    if [[ "$SSH_PORT" != "22" ]]; then
        ufw allow ${SSH_PORT}/tcp comment 'Allow Custom SSH' >/dev/null
        log_info "已开放自定义SSH端口: ${SSH_PORT}。"
    fi
    # 设定默认策略
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    log_info "防火墙默认策略已设置为: 拒绝所有入站，允许所有出站。"


    
  

    log_warning "即将启用防火墙！"
    ufw --force enable
    if [ $? -eq 0 ]; then
        log_success "防火墙已配置并成功启用。"
    else
        log_error "防火墙启用失败！脚本中止。"
        exit 1
    fi
}

# 8. 设置时区
set_timezone() {
    log_info "设置时区为 ${TIMEZONE}..."
    timedatectl set-timezone ${TIMEZONE}
    log_success "时区设置完成。"
}

# 9. 创建Swap文件
create_swap_file() {
    log_info "开始创建 ${SWAP_SIZE_GB}GB 大小的Swap文件..."
    fallocate -l ${SWAP_SIZE_GB}G /swapfile
    if [ $? -ne 0 ]; then
        log_warning "fallocate创建Swap文件失败，可能文件系统不支持。尝试使用dd创建 (可能较慢)..."
        dd if=/dev/zero of=/swapfile bs=1G count=${SWAP_SIZE_GB} status=progress
    fi
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    log_success "Swap创建并激活成功!"
}

# 10. 安装Docker
install_docker() {
    log_info "开始使用Docker官方脚本安装Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    if [ $? -ne 0 ]; then
        log_error "Docker安装失败！请检查网络或手动执行 sh get-docker.sh 进行排查。"
        rm -f get-docker.sh
        return
    fi
    log_success "Docker安装成功！"
    rm -f get-docker.sh
    if [ -n "$DOCKER_USER" ]; then
        log_info "将用户 '$DOCKER_USER' 添加到 'docker' 组..."
        usermod -aG docker "$DOCKER_USER"
        log_success "用户 '$DOCKER_USER' 已成功添加到 'docker' 组。"
        log_warning "用户 '$DOCKER_USER' 需要重新登录服务器，才能免sudo使用docker命令！"
    fi
}


# --- 主程序开始 ---

if [ "$(id -u)" -ne 0 ]; then
   log_error "此脚本必须以root用户身份运行。请使用 'su -' 或 'sudo su -' 切换到root用户后执行。"
   exit 1
fi

clear
echo "====================================================="
echo "服务器初始化脚本"
echo "====================================================="
echo

# --- 收集用户信息 ---
ask_ssh_port
ask_timezone
ask_and_configure_swap
ask_install_docker

# --- 显示配置摘要并请求最终确认 ---
clear
echo "==============================================="
echo "      请确认以下配置"
echo "==============================================="
echo -e "计划使用的SSH端口    : ${YELLOW}${SSH_PORT}${NC}"
echo -e "系统时区             : ${YELLOW}${TIMEZONE}${NC}"
if [ -n "$SWAP_SIZE_GB" ]; then
    echo -e "创建 Swap 大小       : ${YELLOW}${SWAP_SIZE_GB} GB${NC}"
else
    echo -e "创建 Swap 大小       : ${YELLOW}不创建${NC}"
fi
if [ "$INSTALL_DOCKER" == "yes" ]; then
    echo -e "是否安装 Docker      : ${YELLOW}是${NC}"
    if [ -n "$DOCKER_USER" ]; then
        echo -e "添加到docker组的用户 : ${YELLOW}${DOCKER_USER}${NC}"
    else
        echo -e "添加到docker组的用户 : ${YELLOW}未指定${NC}"
    fi
else
    echo -e "是否安装 Docker      : ${YELLOW}否${NC}"
fi
echo
echo -e "脚本将执行以下操作:"
echo -e " 1. 安装 ufw, fail2ban 等基础软件"
echo -e " 2. ${GREEN}配置 Fail2Ban 保护端口 ${SSH_PORT}${NC}"
echo -e " 3. ${GREEN}配置 UFW 防火墙 (开放 80, 443, 22 和 ${SSH_PORT})${NC}"
echo -e " 4. 设置系统时区"
[ -n "$SWAP_SIZE_GB" ] && echo -e " 5. 创建 ${SWAP_SIZE_GB}GB Swap"
[ "$INSTALL_DOCKER" == "yes" ] && echo -e " 6. 安装 Docker"
echo
echo -e "${RED}重要提示: 本脚本不会修改SSH服务本身！执行完毕后，您必须手动修改 /etc/ssh/sshd_config 文件中的端口，并重启SSH服务，才能使用新端口 ${SSH_PORT} 登录！${NC}"
echo

read -p "$(echo -e ${YELLOW}"您确定要继续执行吗？(y/n): "${NC})" confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    log_error "操作已取消。"
    exit 0
fi

# --- 开始执行 ---
log_info "配置已确认，3秒后开始执行..."
sleep 3

install_software
configure_fail2ban
configure_firewall
set_timezone

# 根据用户选择执行可选操作
if [ -n "$SWAP_SIZE_GB" ]; then
    create_swap_file
fi
if [ "$INSTALL_DOCKER" == "yes" ]; then
    install_docker
fi


# --- 最终状态报告 ---
echo
log_success "✅✅✅ 服务器初始化完成! ✅✅✅"
echo
echo "---------- 防火墙状态 ----------"
ufw status verbose
echo "--------------------------------"
echo "---------- Fail2Ban SSH 监控状态 ----------"
fail2ban-client status sshd
echo "--------------------------------"
echo "----------   时间状态   ----------"
timedatectl status | grep "Time zone"
echo "--------------------------------"
echo "----------   Swap状态   ----------"
swapon --show
free -h
echo "--------------------------------"
if [ "$INSTALL_DOCKER" == "yes" ]; then
    echo "----------  Docker状态  ----------"
    docker --version
    echo "--------------------------------"
    if [ -n "$DOCKER_USER" ]; then
      log_warning "Docker已安装，用户 '$DOCKER_USER' 必须重新登录才能无须sudo使用docker！"
    fi
fi

echo -e "\n${RED}======================= 行动号召 ======================="
log_warning "脚本已为您配置好防火墙和Fail2Ban以适配端口 ${SSH_PORT}。"
log_warning "下一步，您【必须】手动完成以下操作："
echo -e "  1. 编辑SSH配置文件: ${YELLOW}sudo nano /etc/ssh/sshd_config${NC}"
echo -e "  2. 找到 'Port ' 这一行，将其修改为: ${YELLOW}Port ${SSH_PORT}${NC}"
echo -e "  3. 保存文件并重启SSH服务: ${YELLOW} systemctl restart sshd${NC}"
echo -e "完成后，您就可以通过新端口 ${SSH_PORT} 连接服务器了。"
echo -e "${RED}=========================================================${NC}"

exit 0
