#!/bin/bash

# 确保脚本以root权限运行
if [ "$(id -u)" != "0" ]; then
    echo "脚本需要root运行." 1>&2
    exit 1
fi

# 获取所有可用网卡并让用户选择
select_network_interface() {
    # 获取所有状态为UP的网卡
    interfaces=$(ip addr | grep 'state UP' | awk '{print $2}' | sed 's/.$//' | cut -d'@' -f1)
    
    # 将网卡列表转换为数组
    IFS=$'\n' read -rd '' -a interface_array <<< "$interfaces"
    
    # 检查是否有可用网卡
    if [ ${#interface_array[@]} -eq 0 ]; then
        echo "错误: 未找到可用的网络接口" 1>&2
        exit 1
    fi
    
    # 如果只有一个网卡，直接使用
    if [ ${#interface_array[@]} -eq 1 ]; then
        nic=${interface_array[0]}
        echo "检测到唯一网络接口: $nic"
        return
    fi
    
    # 如果有多个网卡，让用户选择
    echo "请选择网络接口:"
    for i in "${!interface_array[@]}"; do
        echo "$((i+1))) ${interface_array[i]}"
    done
    
    while true; do
        read -p "请输入选项编号 (1-${#interface_array[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#interface_array[@]} ]; then
            nic=${interface_array[$((choice-1))]}
            break
        else
            echo "无效输入，请输入1-${#interface_array[@]}之间的数字"
        fi
    done
    
    echo "已选择网络接口: $nic"
}

# 调用函数选择网卡
select_network_interface

# 设置带宽限制
bandwidth_limit_() {
    # 安装vnstat如果尚未安装
    if ! [ -x "$(command -v vnstat)" ]; then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install vnstat -y
        elif command -v yum >/dev/null 2>&1; then
            yum install vnstat -y
        else
            echo "不支持的包管理器"
            return 1
        fi
    fi
    
    # 安装bc如果尚未安装
    if ! [ -x "$(command -v bc)" ]; then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get install bc -y
        elif command -v yum >/dev/null 2>&1; then
            yum install bc -y
        else
            echo "不支持的包管理器"
            return 1
        fi
    fi
    
    # 配置vnstat
    sed -i "s/Interface \"\"/Interface \"$nic\"/" /etc/vnstat.conf
    
    # 创建日志轮转配置（保留2个月）
    cat << EOF > /etc/logrotate.d/bandwidth_limit
/var/log/bandwidth_limit.log {
    monthly
    rotate 2
    compress
    missingok
    notifempty
    create 0640 root adm
    postrotate
        systemctl restart bandwidth_limit >/dev/null 2>&1 || true
    endscript
}
EOF

    # 创建带宽限制脚本
    cat << EOF > /root/.bandwidth_limit.sh
#!/bin/bash

# 设置每月限制（GiB）
monthly_upload_limit=$upload_threshold
monthly_download_limit=$download_threshold
reset_day=$reset_day
check_interval=$check_interval  # 用户设置的检查间隔（秒）
direction=$direction  # 用户选择的统计方向
nic="$nic"  # 用户选择的网络接口
LOG_FILE="/var/log/bandwidth_limit.log"

# 初始化日志文件
touch \$LOG_FILE
chmod 640 \$LOG_FILE

log_message() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1" >> \$LOG_FILE
}

# 等待vnstat初始化完成
log_message "等待vnstat初始化网络接口 \$nic..."
while true; do
    # 检查vnstat是否有数据
    vnstat_data=\$(vnstat -i "\$nic" --oneline 2>/dev/null)
    if [ -n "\$vnstat_data" ] && [ "\$vnstat_data" != ";" ]; then
        log_message "vnstat初始化完成"
        break
    fi
    log_message "vnstat尚未收集到数据，等待30秒..."
    sleep 30
done

while true
do
    # 获取当前日期
    current_year=\$(date +%Y)
    current_month=\$(date +%m)
    current_day=\$(date +%d)

    # 计算vnStat的开始和结束日期
    if [[ \$current_day -ge \$reset_day ]]; then
        begin_date="\$current_year-\$current_month-\$reset_day"
        next_month=\$(date -d "\$begin_date +1 month" +%m)
        next_year=\$(date -d "\$begin_date +1 month" +%Y)
        end_date="\$next_year-\$next_month-\$reset_day"
    else
        end_date="\$current_year-\$current_month-\$reset_day"
        prev_month=\$(date -d "\$end_date -1 month" +%m)
        prev_year=\$(date -d "\$end_date -1 month" +%Y)
        begin_date="\$prev_year-\$prev_month-\$reset_day"
    fi

    # 检查是否是重置日（每月第一天）
    if [[ \$current_day -eq \$reset_day ]]; then
        # 重置流量统计
        log_message "重置流量统计 - 清空vnStat数据库"
        vnstat -i "\$nic" --delete > /dev/null 2>&1
        # 等待数据库重新初始化
        sleep 10
        continue
    fi

    # 获取当前使用量
    vnstat_output=\$(vnstat --begin \$begin_date --end \$end_date -i "\$nic" --oneline 2>/dev/null)
    
    # 检查vnstat输出是否有效
    if [ -z "\$vnstat_output" ] || [ "\$vnstat_output" = ";" ]; then
        log_message "vnstat未返回有效数据，跳过本次检查"
        sleep \$check_interval
        continue
    fi
    
    # 解析上传流量
    current_upload_usage=\$(echo "\$vnstat_output" | awk -F\; '{print \$10}')
    current_upload_usage_value=\$(echo "\$current_upload_usage" | awk '{print \$1}')
    current_upload_usage_unit=\$(echo "\$current_upload_usage" | awk '{print \$2}')
    
    # 解析下载流量
    current_download_usage=\$(echo "\$vnstat_output" | awk -F\; '{print \$9}')
    current_download_usage_value=\$(echo "\$current_download_usage" | awk '{print \$1}')
    current_download_usage_unit=\$(echo "\$current_download_usage" | awk '{print \$2}')

    # 检查单位是否为空
    if [ -z "\$current_upload_usage_unit" ] || [ -z "\$current_download_usage_unit" ]; then
        log_message "vnstat返回的单位为空，可能是数据不足，跳过本次检查"
        log_message "上传原始数据: \$current_upload_usage, 下载原始数据: \$current_download_usage"
        sleep \$check_interval
        continue
    fi

    # 转换为GiB
    case \$current_upload_usage_unit in
        "KiB") current_upload_usage_in_gib=\$(echo "scale=2; \$current_upload_usage_value / 1048576" | bc) ;;
        "MiB") current_upload_usage_in_gib=\$(echo "scale=2; \$current_upload_usage_value / 1024" | bc) ;;
        "GiB") current_upload_usage_in_gib=\$current_upload_usage_value ;;
        "TiB") current_upload_usage_in_gib=\$(echo "scale=2; \$current_upload_usage_value * 1024" | bc) ;;
        *) 
            log_message "未知上传单位: \$current_upload_usage_unit (原始数据: \$current_upload_usage)"
            sleep \$check_interval
            continue 
            ;;
    esac
    case \$current_download_usage_unit in
        "KiB") current_download_usage_in_gib=\$(echo "scale=2; \$current_download_usage_value / 1048576" | bc) ;;
        "MiB") current_download_usage_in_gib=\$(echo "scale=2; \$current_download_usage_value / 1024" | bc) ;;
        "GiB") current_download_usage_in_gib=\$current_download_usage_value ;;
        "TiB") current_download_usage_in_gib=\$(echo "scale=2; \$current_download_usage_value * 1024" | bc) ;;
        *) 
            log_message "未知下载单位: \$current_download_usage_unit (原始数据: \$current_download_usage)"
            sleep \$check_interval
            continue 
            ;;
    esac

    # 根据用户选择记录日志
    case \$direction in
        1) # 双向统计
            log_message "当前使用量 - 上传: \${current_upload_usage_in_gib}GiB / \${monthly_upload_limit}GiB, 下载: \${current_download_usage_in_gib}GiB / \${monthly_download_limit}GiB"
            ;;
        2) # 只统计入站（下载）
            log_message "当前使用量 - 下载: \${current_download_usage_in_gib}GiB / \${monthly_download_limit}GiB"
            ;;
        3) # 只统计出站（上传）
            log_message "当前使用量 - 上传: \${current_upload_usage_in_gib}GiB / \${monthly_upload_limit}GiB"
            ;;
    esac

    # 根据用户选择检查流量限制
    exceeded=0
    case \$direction in
        1) # 双向统计
            if (( \$(echo "\$current_upload_usage_in_gib >= \$monthly_upload_limit" | bc -l) )); then
                log_message "上传流量超过限制 (\${current_upload_usage_in_gib}GiB >= \${monthly_upload_limit}GiB)，系统将关机"
                exceeded=1
            fi
            if (( \$(echo "\$current_download_usage_in_gib >= \$monthly_download_limit" | bc -l) )); then
                log_message "下载流量超过限制 (\${current_download_usage_in_gib}GiB >= \${monthly_download_limit}GiB)，系统将关机"
                exceeded=1
            fi
            ;;
        2) # 只统计入站（下载）
            if (( \$(echo "\$current_download_usage_in_gib >= \$monthly_download_limit" | bc -l) )); then
                log_message "下载流量超过限制 (\${current_download_usage_in_gib}GiB >= \${monthly_download_limit}GiB)，系统将关机"
                exceeded=1
            fi
            ;;
        3) # 只统计出站（上传）
            if (( \$(echo "\$current_upload_usage_in_gib >= \$monthly_upload_limit" | bc -l) )); then
                log_message "上传流量超过限制 (\${current_upload_usage_in_gib}GiB >= \${monthly_upload_limit}GiB)，系统将关机"
                exceeded=1
            fi
            ;;
    esac

    # 如果超过限制则关机
    if [ \$exceeded -eq 1 ]; then
        shutdown -h now
    fi

    sleep \$check_interval
done
EOF

    chmod +x /root/.bandwidth_limit.sh
    
    # 创建systemd服务
    cat << EOF > /etc/systemd/system/bandwidth_limit.service
[Unit]
Description=Bandwidth Limit
After=network.target

[Service]
Type=simple
ExecStart=/root/.bandwidth_limit.sh
Restart=always
RestartSec=10
StandardOutput=file:/var/log/bandwidth_limit.log
StandardError=file:/var/log/bandwidth_limit.log
SyslogIdentifier=bandwidth_limit
    
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable bandwidth_limit
    systemctl start bandwidth_limit
    return 0
}

# 主程序
echo "设置每月带宽上限"
echo "请选择统计方向："
echo "1) 双向统计（入站+出站）"
echo "2) 只统计入站（下载）"
echo "3) 只统计出站（上传）"
read direction
while ! [[ "$direction" =~ ^[1-3]$ ]]; do
    echo "请输入1-3之间的数字"
    echo "请选择统计方向："
    echo "1) 双向统计（入站+出站）"
    echo "2) 只统计入站（下载）"
    echo "3) 只统计出站（上传）"
    read direction
done

if [ "$direction" == "1" ] || [ "$direction" == "3" ]; then
    echo "输入每月带宽上传上限（以GB为单位）："
    read upload_threshold
    while ! [[ "$upload_threshold" =~ ^[0-9]+$ ]]; do
        echo "请输入数字"
        echo "输入每月带宽上传上限（以GB为单位）："
        read upload_threshold
    done
else
    upload_threshold=0  # 不使用上传限制时设为0
fi

if [ "$direction" == "1" ] || [ "$direction" == "2" ]; then
    echo "输入每月带宽下载上限（以GB为单位）："
    read download_threshold
    while ! [[ "$download_threshold" =~ ^[0-9]+$ ]]; do
        echo "请输入数字"
        echo "输入每月带宽下载上限（以GB为单位）："
        read download_threshold
    done
else
    download_threshold=0  # 不使用下载限制时设为0
fi

echo "输入带宽刷新日 (01-31):"
read reset_day
while ! [[ $reset_day =~ ^[0-9]{1,2}$ ]] || [ $reset_day -lt 1 ] || [ $reset_day -gt 31 ]; do
    echo "请输入01-31之间的数字"
    echo "输入带宽刷新日 (01-31):"
    read reset_day
done
reset_day=$(printf "%02d" $reset_day)

echo "输入流量统计频率（秒）："
read check_interval
while ! [[ "$check_interval" =~ ^[0-9]+$ ]] || [ $check_interval -lt 1 ]; do
    echo "请输入大于0的整数"
    echo "输入流量统计频率（秒）："
    read check_interval
done

if bandwidth_limit_; then
    echo "每月带宽上限设置成功"
    echo "网络接口: $nic"
    echo "日志文件位置: /var/log/bandwidth_limit.log"
    echo "统计频率: 每 $check_interval 秒"
    echo "日志保留: 最近2个月"
    echo "日志轮转: 系统已自动配置logrotate，无需手动添加cron任务"
    
    # 显示用户选择的统计方向
    case $direction in
        1) echo "统计方向: 双向统计（入站+出站）" ;;
        2) echo "统计方向: 只统计入站（下载）" ;;
        3) echo "统计方向: 只统计出站（上传）" ;;
    esac
    
    echo "注意: 脚本启动后需要等待vnstat收集足够数据才能正常工作"
else
    echo "每月带宽上限设置失败"
    exit 1
fi
