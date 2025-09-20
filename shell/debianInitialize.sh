#!/bin/bash

# ==============================================================================
# Debian服务器初始化交互式脚本
#
# 功能:
# 1.  交互式选择是否更换APT源
# 2.  更新系统并安装 ufw, curl, wget
# 3.  交互式设置防火墙要保护的SSH端口 (不会自动修改SSH服务)
# 4.  交互式选择并配置DNS服务器
# 5.  配置 UFW 防火墙
# 6.  交互式设置时区
# 7.  交互式选择是否创建Swap，并自定义大小
# 8.  交互式选择是否安装Docker，并:
#     - 询问是否使用国内镜像源安装
#     - 询问是否配置全局日志轮换
#     - 指定一个用户加入docker组
# 9.  交互式选择是否配置Zram压缩
# 10. 交互式选择是否开启BBR拥塞控制
# 11. 交互式选择是否启用unattended-upgrades自动安全更新
#
# 使用方法: bash <(curl -sSL https://raw.githubusercontent.com/XyzenSun/MyScripts/refs/heads/main/shell/debianInitialize.sh)
# 国内可用Github下载代理bash <(curl -sSL https://gh-proxy.com/https://raw.githubusercontent.com/XyzenSun/MyScripts/refs/heads/main/shell/debianInitialize.sh)
# ==============================================================================

# --- 配置颜色输出 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- 全局变量 ---
CHANGE_MIRROR="yes"
SSH_PORT=""
TIMEZONE=""
SWAP_SIZE_GB=""
INSTALL_DOCKER=""
USE_DOCKER_MIRROR="no" # 新增: 是否使用Docker国内镜像源
CONFIGURE_DOCKER_LOGS=""
DOCKER_USER=""
ENABLE_ZRAM=""
ZRAM_SIZE=""
ENABLE_BBR=""
ENABLE_UNATTENDED_UPGRADES=""
CHANGE_DNS=""
DNS_SERVERS=""

# --- 函数定义 ---

# 日志打印函数
log_info() { echo -e "${BLUE}[INFO] $1${NC}"; }
log_success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }
log_warning() { echo -e "${YELLOW}[WARNING] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; }

# 0. 询问是否更换软件源
ask_change_mirror() {
    read -p "$(echo -e ${YELLOW}"是否需要更换为速度更快的国内软件源(APT Mirror)? (y/n) [默认 y]: "${NC})" mirror_choice
    if [[ "$mirror_choice" == "n" || "$mirror_choice" == "N" ]]; then
        CHANGE_MIRROR="no"
    else
        CHANGE_MIRROR="yes"
    fi
}

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
    DEFAULT_TIMEZONE="Asia/Shanghai"
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
        
        # 新增: 询问是否使用国内镜像源
        read -p "$(echo -e ${YELLOW}"是否使用国内镜像源安装Docker (推荐国内服务器)? (y/n) [默认 y]: "${NC})" docker_mirror_choice
        if [[ "$docker_mirror_choice" == "n" || "$docker_mirror_choice" == "N" ]]; then
            USE_DOCKER_MIRROR="no"
        else
            USE_DOCKER_MIRROR="yes"
        fi

        # 询问是否配置日志轮换
        read -p "$(echo -e ${YELLOW}"是否为Docker配置全局日志轮换 (10m*3个文件)? (y/n) [默认 y]: "${NC})" docker_log_choice
        if [[ "$docker_log_choice" == "n" || "$docker_log_choice" == "N" ]]; then
            CONFIGURE_DOCKER_LOGS="no"
        else
            CONFIGURE_DOCKER_LOGS="yes"
        fi

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
        CONFIGURE_DOCKER_LOGS="no"
        USE_DOCKER_MIRROR="no"
    fi
}

# 5. 询问是否启用Zram
ask_zram() {
    read -p "$(echo -e ${YELLOW}"是否需要启用Zram压缩 (内存压缩交换)? (y/n) [默认 n]: "${NC})" zram_choice
    if [[ "$zram_choice" == "y" || "$zram_choice" == "Y" ]]; then
        ENABLE_ZRAM="yes"
        while true; do
            read -p "$(echo -e ${YELLOW}"请输入Zram大小 (单位: MB, 例如: 1536): "${NC})" ZRAM_SIZE_INPUT
            if [[ "$ZRAM_SIZE_INPUT" =~ ^[1-9][0-9]*$ ]]; then
                ZRAM_SIZE=$ZRAM_SIZE_INPUT
                break
            else
                log_error "无效输入！请输入一个正整数。"
            fi
        done
    else
        ENABLE_ZRAM="no"
    fi
}

# 6. 询问是否启用BBR
ask_bbr() {
    read -p "$(echo -e ${YELLOW}"是否需要启用BBR拥塞控制算法 (提升网络性能)? (y/n) [默认 n]: "${NC})" bbr_choice
    if [[ "$bbr_choice" == "y" || "$bbr_choice" == "Y" ]]; then
        ENABLE_BBR="yes"
    else
        ENABLE_BBR="no"
    fi
}

# 7. (新) 询问是否启用自动安全更新
ask_unattended_upgrades() {
    read -p "$(echo -e ${YELLOW}"是否需要启用 unattended-upgrades 自动安全更新? (y/n) [默认 y]: "${NC})" unattended_choice
    if [[ "$unattended_choice" == "n" || "$unattended_choice" == "N" ]]; then
        ENABLE_UNATTENDED_UPGRADES="no"
    else
        ENABLE_UNATTENDED_UPGRADES="yes"
    fi
}

# 8. 询问并配置DNS
ask_dns() {
    read -p "$(echo -e ${YELLOW}"是否需要更改系统的DNS服务器? (y/n) [默认 n]: "${NC})" dns_choice
    if [[ "$dns_choice" != "y" && "$dns_choice" != "Y" ]]; then
        CHANGE_DNS="no"
        return
    fi
    CHANGE_DNS="yes"
  
    log_info "以下是可用的DNS服务器 (仅支持IPv4):"
    echo -e "
    ${GREEN}国内服务商:${NC}
    [1] 腾讯 (DNSPod)      : 119.29.29.29
    [2] 阿里 (AliDNS)      : 223.5.5.5, 223.6.6.6
    [3] 114 DNS (纯净)     : 114.114.114.114, 114.114.115.115
    [4] 114 DNS (安全)     : 114.114.114.119, 114.114.115.119
    [5] 114 DNS (家庭)     : 114.114.114.110, 114.114.115.110
    [6] 百度 (BaiduDNS)    : 180.76.76.76
    ${GREEN}国外服务商:${NC}
    [7] CloudFlare         : 1.1.1.1, 1.0.0.1
    [8] Google             : 8.8.8.8, 8.8.4.4
    [9] OpenDNS            : 208.67.222.222, 208.67.220.220
    [10] IBM (Quad9)       : 9.9.9.9, 149.112.112.112
    "
  
    while true; do
        read -p "$(echo -e ${YELLOW}"请选择您要使用的DNS编号，可多选，用空格隔开 (例如: 2 7)，输入0取消: "${NC})" -a choices
        DNS_SERVERS="" # 重置
        for choice in "${choices[@]}"; do
            case $choice in
                1) DNS_SERVERS+="119.29.29.29 " ;;
                2) DNS_SERVERS+="223.5.5.5 223.6.6.6 " ;;
                3) DNS_SERVERS+="114.114.114.114 114.114.115.115 " ;;
                4) DNS_SERVERS+="114.114.114.119 114.114.115.119 " ;;
                5) DNS_SERVERS+="114.114.114.110 114.114.115.110 " ;;
                6) DNS_SERVERS+="180.76.76.76 " ;;
                7) DNS_SERVERS+="1.1.1.1 1.0.0.1 " ;;
                8) DNS_SERVERS+="8.8.8.8 8.8.4.4 " ;;
                9) DNS_SERVERS+="208.67.222.222 208.67.220.220 " ;;
                10) DNS_SERVERS+="9.9.9.9 149.112.112.112 " ;;
                0) DNS_SERVERS=""; CHANGE_DNS="no"; break ;;
                *) log_warning "检测到无效选择: $choice";;
            esac
        done
      
        DNS_SERVERS=$(echo "$DNS_SERVERS" | xargs)
      
        if [[ "$CHANGE_DNS" == "no" ]]; then
            log_info "用户取消了DNS设置。"
            break
        fi

        if [ -n "$DNS_SERVERS" ]; then
            log_success "您已选择的DNS服务器: $DNS_SERVERS"
            break
        else
            log_error "无效选择，请重新输入。"
        fi
    done
}


# 9. 更换软件源
change_apt_mirror() {
    log_info "正在准备更换APT软件源..."
    if ! command -v curl &> /dev/null; then
        log_warning "未找到 'curl' 命令，正在尝试安装..."
        apt-get update >/dev/null 2>&1
        apt-get install -y curl
        if [ $? -ne 0 ]; then
            log_error "安装 'curl' 失败。无法继续更换软件源，将使用系统默认源。请检查网络或手动安装curl。"
            return 1
        fi
        log_success "'curl' 安装成功。"
    fi
  
    log_info "即将执行换源脚本，请根据提示进行交互选择..."
    sleep 2
    bash <(curl -sSL https://linuxmirrors.cn/main.sh)
    if [ $? -eq 0 ]; then
        log_success "软件源更换脚本执行完成。"
    else
        log_error "软件源更换脚本执行失败或被取消。后续将使用原有软件源。"
    fi
}

# 10. 执行系统更新和软件安装
install_software() {
    log_info "开始更新系统并安装必要软件 (ufw, curl, wget)..."
    apt-get update >/dev/null 2>&1 && apt-get install -y ufw curl wget
    if [ $? -ne 0 ]; then
        log_error "软件安装失败，请检查apt源或网络连接。脚本中止。"
        exit 1
    fi
    log_success "基础软件安装完成。"
}

# 11. (新) 配置自动安全更新
configure_unattended_upgrades() {
    log_info "开始安装并配置 unattended-upgrades..."
    apt-get install -y unattended-upgrades
    if [ $? -ne 0 ]; then
        log_error "安装 unattended-upgrades 失败！"
        return
    fi
    
    dpkg-reconfigure -plow unattended-upgrades
    
    if [ -f "/etc/apt/apt.conf.d/20auto-upgrades" ]; then
        log_success "unattended-upgrades 配置成功，系统将自动安装安全更新。"
    else
        log_error "配置 unattended-upgrades 失败，请手动检查。"
    fi
}

# 12. 配置防火墙
configure_firewall() {
    log_info "配置防火墙(UFW)..."
    ufw allow 80/tcp comment 'Allow HTTP' >/dev/null
    ufw allow 443/tcp comment 'Allow HTTPS' >/dev/null
    ufw allow 22/tcp comment 'Allow SSH fallback' >/dev/null
    log_info "已开放端口: 80 (HTTP), 443 (HTTPS), 22 (SSH后备)。"
    if [[ "$SSH_PORT" != "22" ]]; then
        ufw allow ${SSH_PORT}/tcp comment 'Allow Custom SSH' >/dev/null
        log_info "已开放自定义SSH端口: ${SSH_PORT}。"
    fi
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

# 13. 设置时区
set_timezone() {
    log_info "设置时区为 ${TIMEZONE}..."
    timedatectl set-timezone ${TIMEZONE}
    log_success "时区设置完成。"
}

# 14. 创建Swap文件
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

# 15. 安装Docker (已修改)
install_docker() {
    local install_status=1 # 默认失败

    if [ "$USE_DOCKER_MIRROR" == "yes" ]; then
        log_info "开始使用国内镜像源脚本 (linuxmirrors.cn) 安装Docker..."
        bash <(curl -sSL https://linuxmirrors.cn/docker.sh)
        install_status=$?
    else
        log_info "开始使用Docker官方脚本安装Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        install_status=$?
        rm -f get-docker.sh
    fi

    # 统一检查安装结果
    if [ $install_status -ne 0 ] || ! command -v docker &> /dev/null; then
        log_error "Docker安装失败！请检查网络或手动执行安装脚本进行排查。"
        return 1
    fi
    
    log_success "Docker安装成功！"

    if [ -n "$DOCKER_USER" ]; then
        log_info "将用户 '$DOCKER_USER' 添加到 'docker' 组..."
        usermod -aG docker "$DOCKER_USER"
        log_success "用户 '$DOCKER_USER' 已成功添加到 'docker' 组。"
        log_warning "用户 '$DOCKER_USER' 需要重新登录服务器，才能免sudo使用docker命令！"
    fi
}

# 16. 配置Docker日志轮换
configure_docker_logs() {
    log_info "开始为Docker配置全局日志轮换..."
    mkdir -p /etc/docker
    
    cat > /etc/docker/daemon.json << EOF
{
        "log-driver": "json-file",
        "log-opts": {
                "max-file": "3",
                "max-size": "10m"
        }
}
EOF

    if [ $? -eq 0 ]; then
        log_success "Docker日志配置文件 /etc/docker/daemon.json 创建/覆盖成功。"
        log_info "已将全局Docker日志设置为: 最多3个文件，每个文件最大10MB。"
        log_info "您可以随时通过编辑 /etc/docker/daemon.json 文件来修改此配置。"
        log_info "正在重启Docker以应用配置..."
        systemctl restart docker
        if [ $? -eq 0 ]; then
            log_success "Docker重启成功，日志配置已生效。"
        else
            log_error "Docker重启失败，请手动执行 'systemctl restart docker'。"
        fi
    else
        log_error "创建 /etc/docker/daemon.json 文件失败！"
    fi
}

# 17. 配置Zram
configure_zram() {
    log_info "开始安装和配置Zram..."
    apt-get update >/dev/null 2>&1 && apt-get install -y zram-tools
    if [ $? -ne 0 ]; then
        log_error "安装 zram-tools 失败！"
        return
    fi
    if [ -f /etc/default/zramswap ]; then
        cp /etc/default/zramswap "/etc/default/zramswap.bak_$(date +%Y%m%d_%H%M%S)"
        log_info "已备份原有Zram配置文件。"
    fi
    cat > /etc/default/zramswap << EOF
# Compression algorithm (lz4 is fast and efficient)
ALGO=lz4
# Size in MB
SIZE=${ZRAM_SIZE}
# Priority (higher number = higher priority)
PRIORITY=100
EOF
    systemctl restart zramswap.service
    if [ $? -eq 0 ]; then
        log_success "Zram配置完成并启用！"
    else
        log_error "Zram服务启动失败！"
    fi
}

# 18. 配置BBR
configure_bbr() {
    log_info "开始配置BBR拥塞控制算法..."
    cp /etc/sysctl.conf "/etc/sysctl.conf.bak_$(date +%Y%m%d_%H%M%S)"
    log_info "已备份原有sysctl配置文件。"
    if grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        log_warning "检测到BBR已配置，跳过重复配置。"
        return
    fi
    printf "%s\n" "net.core.default_qdisc=fq" "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl --system >/dev/null 2>&1
    sysctl -p >/dev/null 2>&1
    log_info "检查BBR配置状态..."
    qdisc_output=$(sysctl net.core.default_qdisc 2>/dev/null | grep -o 'fq')
    bbr_output=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -o 'bbr')
    bbr_module=$(lsmod | grep bbr)
    if [[ "$qdisc_output" == "fq" && "$bbr_output" == "bbr" && -n "$bbr_module" ]]; then
        log_success "BBR拥塞控制算法配置成功并已生效！"
    else
        log_warning "BBR配置完成，但可能需要重启系统才能完全生效。"
    fi
}

# 19. 配置DNS
configure_dns() {
    log_info "开始配置DNS服务器..."
    cp /etc/systemd/resolved.conf "/etc/systemd/resolved.conf.bak_$(date +%Y%m%d_%H%M%S)"
    log_info "已备份原有DNS配置文件 /etc/systemd/resolved.conf"
    sed -i -e 's/^#*DNS=.*/#&/' -e 's/^#*FallbackDNS=.*/#&/' /etc/systemd/resolved.conf
    if ! grep -q "\[Resolve\]" /etc/systemd/resolved.conf; then
        echo "[Resolve]" >> /etc/systemd/resolved.conf
    fi
    sed -i "/\[Resolve\]/a DNS=${DNS_SERVERS}" /etc/systemd/resolved.conf
    systemctl restart systemd-resolved.service
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    log_success "DNS服务器已成功配置！"
}


# --- 主程序开始 ---

if [ "$(id -u)" -ne 0 ]; then
   log_error "此脚本必须以root用户身份运行。请使用 'su -' 或 'sudo su -' 切换到root用户后执行。"
   exit 1
fi

clear
echo "====================================================="
echo "      服务器初始化脚本"
echo "====================================================="
echo

# --- 收集用户信息 ---
ask_change_mirror
ask_ssh_port
ask_timezone
ask_dns
ask_and_configure_swap
ask_install_docker
ask_zram
ask_bbr
ask_unattended_upgrades

# --- 显示配置摘要并请求最终确认 ---
clear
echo "==============================================="
echo "      请确认以下配置"
echo "==============================================="
if [ "$CHANGE_MIRROR" == "yes" ]; then
    echo -e "更换国内软件源       : ${GREEN}是${NC}"
else
    echo -e "更换国内软件源       : ${YELLOW}否${NC}"
fi
echo -e "计划使用的SSH端口    : ${YELLOW}${SSH_PORT}${NC}"
echo -e "系统时区             : ${YELLOW}${TIMEZONE}${NC}"
if [ "$CHANGE_DNS" == "yes" ]; then
    echo -e "DNS 服务器           : ${YELLOW}${DNS_SERVERS}${NC}"
else
    echo -e "DNS 服务器           : ${YELLOW}保持系统默认${NC}"
fi
if [ -n "$SWAP_SIZE_GB" ]; then
    echo -e "创建 Swap 大小       : ${YELLOW}${SWAP_SIZE_GB} GB${NC}"
else
    echo -e "创建 Swap 大小       : ${YELLOW}不创建${NC}"
fi
if [ "$INSTALL_DOCKER" == "yes" ]; then
    echo -e "是否安装 Docker      : ${GREEN}是${NC}"
    if [ "$USE_DOCKER_MIRROR" == "yes" ]; then
        echo -e "  - 使用国内镜像安装   : ${GREEN}是${NC}"
    else
        echo -e "  - 使用国内镜像安装   : ${YELLOW}否 (使用官方源)${NC}"
    fi
    if [ "$CONFIGURE_DOCKER_LOGS" == "yes" ]; then
        echo -e "  - 配置Docker日志轮换 : ${GREEN}是${NC}"
    else
        echo -e "  - 配置Docker日志轮换 : ${YELLOW}否${NC}"
    fi
    if [ -n "$DOCKER_USER" ]; then
        echo -e "  - 添加到docker组的用户 : ${YELLOW}${DOCKER_USER}${NC}"
    else
        echo -e "  - 添加到docker组的用户 : ${YELLOW}未指定${NC}"
    fi
else
    echo -e "是否安装 Docker      : ${YELLOW}否${NC}"
fi
if [ "$ENABLE_ZRAM" == "yes" ]; then
    echo -e "启用 Zram 压缩       : ${GREEN}是 (${ZRAM_SIZE}MB)${NC}"
else
    echo -e "启用 Zram 压缩       : ${YELLOW}否${NC}"
fi
if [ "$ENABLE_BBR" == "yes" ]; then
    echo -e "启用 BBR 拥塞控制    : ${GREEN}是${NC}"
else
    echo -e "启用 BBR 拥塞控制    : ${YELLOW}否${NC}"
fi
if [ "$ENABLE_UNATTENDED_UPGRADES" == "yes" ]; then
    echo -e "自动安全更新         : ${GREEN}是${NC}"
else
    echo -e "自动安全更新         : ${YELLOW}否${NC}"
fi
echo
echo -e "脚本将执行以下操作:"
[ "$CHANGE_MIRROR" == "yes" ] && echo -e " 1. ${GREEN}更换系统软件源 (APT Mirror) 以加速下载${NC}"
echo -e " 2. 安装 ufw, curl, wget 等基础软件"
[ "$ENABLE_UNATTENDED_UPGRADES" == "yes" ] && echo -e " 3. ${GREEN}启用 unattended-upgrades 自动安全更新${NC}"
echo -e " 4. ${GREEN}配置 UFW 防火墙 (开放 80, 443, 22 和 ${SSH_PORT})${NC}"
echo -e " 5. 设置系统时区"
[ "$CHANGE_DNS" == "yes" ] && echo -e " 6. 更改系统DNS服务器"
[ -n "$SWAP_SIZE_GB" ] && echo -e " 7. 创建 ${SWAP_SIZE_GB}GB Swap"
[ "$INSTALL_DOCKER" == "yes" ] && echo -e " 8. 安装 Docker 并进行相应配置"
[ "$ENABLE_ZRAM" == "yes" ] && echo -e " 9. 配置 Zram 压缩 (${ZRAM_SIZE}MB)"
[ "$ENABLE_BBR" == "yes" ] && echo -e " 10. 启用 BBR 拥塞控制算法"
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

if [ "$CHANGE_MIRROR" == "yes" ]; then
    change_apt_mirror
fi

install_software

if [ "$ENABLE_UNATTENDED_UPGRADES" == "yes" ]; then
    configure_unattended_upgrades
fi

configure_firewall
set_timezone

if [ "$CHANGE_DNS" == "yes" ]; then
    configure_dns
fi
if [ -n "$SWAP_SIZE_GB" ]; then
    create_swap_file
fi
if [ "$INSTALL_DOCKER" == "yes" ]; then
    install_docker
    if [ $? -eq 0 ] && [ "$CONFIGURE_DOCKER_LOGS" == "yes" ]; then
        configure_docker_logs
    fi
fi
if [ "$ENABLE_ZRAM" == "yes" ]; then
    configure_zram
fi
if [ "$ENABLE_BBR" == "yes" ]; then
    configure_bbr
fi

# --- 最终状态报告 ---
echo
log_success "✅✅✅ 服务器初始化完成! ✅✅✅"
echo
echo "---------- 防火墙状态 ----------"
ufw status verbose
echo "--------------------------------"
echo "----------   时间状态   ----------"
timedatectl status | grep "Time zone"
echo "--------------------------------"
if [ "$ENABLE_UNATTENDED_UPGRADES" == "yes" ]; then
    echo "---------- 自动更新状态 ----------"
    if [ -f "/etc/apt/apt.conf.d/20auto-upgrades" ]; then
        echo "Unattended-upgrades: 配置文件存在，内容如下:"
        cat /etc/apt/apt.conf.d/20auto-upgrades
    else
        echo "Unattended-upgrades: ${RED}配置文件未找到!${NC}"
    fi
    echo "--------------------------------"
fi
if [ "$CHANGE_DNS" == "yes" ]; then
    echo "----------   DNS状态    ----------"
    resolvectl status | grep "Current DNS Server" || systemd-resolve --status | grep "Current DNS Server"
    echo "--------------------------------"
fi
echo "----------   Swap/Zram状态   ----------"
swapon --show
free -h
echo "--------------------------------"
if [ "$INSTALL_DOCKER" == "yes" ]; then
    echo "----------  Docker状态  ----------"
    if command -v docker &> /dev/null; then
        docker --version
        if [ -f "/etc/docker/daemon.json" ]; then
            echo "日志轮换配置: 已配置 (/etc/docker/daemon.json)"
        fi
        if [ -n "$DOCKER_USER" ]; then
          log_warning "Docker已安装，用户 '$DOCKER_USER' 必须重新登录才能无须sudo使用docker！"
        fi
    else
        log_error "Docker未成功安装。"
    fi
    echo "--------------------------------"
fi
if [ "$ENABLE_BBR" == "yes" ]; then
    echo "----------   BBR状态    ----------"
    echo "Queue Discipline: $(sysctl net.core.default_qdisc 2>/dev/null)"
    echo "Congestion Control: $(sysctl net.ipv4.tcp_congestion_control 2>/dev/null)"
    echo "BBR Module: $(lsmod | grep bbr || echo 'Not loaded')"
    echo "--------------------------------"
fi

echo -e "\n${RED}======================= 行动号召 ======================="
log_warning "脚本已为您配置好防火墙以适配端口 ${SSH_PORT}。"
log_warning "下一步，您【必须】手动完成以下操作："
echo -e "  1. 编辑SSH配置文件: ${YELLOW}sudo nano /etc/ssh/sshd_config${NC}"
echo -e "  2. 找到 'Port ' 这一行，将其修改为: ${YELLOW}Port ${SSH_PORT}${NC}"
echo -e "  3. 保存文件并重启SSH服务: ${YELLOW} systemctl restart sshd${NC}"
echo -e "完成后，您就可以通过新端口 ${SSH_PORT} 连接服务器了。"
echo -e "${RED}=========================================================${NC}"

exit 0
