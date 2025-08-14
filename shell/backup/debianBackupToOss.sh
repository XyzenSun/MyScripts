#!/bin/bash

# --- 脚本说明 ---
# 功能：使用 rclone 将指定的本地目录以版本化的方式备份到远OSS
#      采用 "Fail-Fast" 策略，任何关键步骤失败都会立即中止脚本。
#      仅在发生底层网络错误时进行单次重试。
# --- 配置区 ---

#  rclone 中配置的远程存储的名称 (通过 "rclone config" 创建)
RCLONE_REMOTE_NAME=""

# 在这里填写您真实的OsS桶名。
ACTUAL_BUCKET_NAME="" 

# 在OBS桶内用于存放所有备份数据的根目录名称
REMOTE_FOLDER_INSIDE_BUCKET=""

# 【可选】您希望备份其家目录和定时任务的主要用户名。
# 如果此行为空、被注释或删除，脚本将自动跳过与该用户相关的备份。
PRIMARY_USER=""

# 用于暂存元数据文件的本地临时目录
LOCAL_TEMP_STAGING_DIR="/tmp/rclone_backup_staging_$$"

# Rclone 的核心运行参数
RCLONE_OPTS=(
    --verbose                   # 输出详细的文件传输信息
    --checkers=8                # 并行检查文件的数量
    --transfers=4               # 并行传输文件的数量
    --buffer-size=16M           # 文件传输时使用的内存缓冲区大小
    --stats=1m                  # 每分钟打印一次传输状态
    --stats-one-line            # 将状态信息压缩到一行显示
    --fast-list                 # 优化大型目录列表的处理
    --retries=1                 # 操作级重试次数设为1 (不重试)，确保脚本逻辑的严格性
    --low-level-retries=1       # 【需求实现】仅在网络层面（如HTTP 5xx错误）重试1次
)
# --- 配置区结束 ---


# --- 函数定义 ---

# 带时间戳的日志记录函数
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# 打印错误信息并退出的函数
error_exit() {
    log_message "错误 (FATAL): $1"
    log_message "备份过程已中止。"
    cleanup_staging # 在退出前尝试清理临时文件
    exit 1
}

# 清理临时暂存目录的函数
cleanup_staging() {
    if [ -d "$LOCAL_TEMP_STAGING_DIR" ]; then
        log_message "正在清理临时目录: $LOCAL_TEMP_STAGING_DIR"
        rm -rf "$LOCAL_TEMP_STAGING_DIR"
    fi
}
# --- 函数定义结束 ---


# --- 主逻辑开始 ---

# 确保脚本在任何情况下退出时，都会尝试清理临时文件
trap cleanup_staging EXIT SIGINT SIGTERM

log_message "备份脚本启动..."

# 1. 权限与环境检查
if [ "$(id -u)" -ne 0 ]; then
   error_exit "此脚本需要以 root 权限运行。请尝试使用 'sudo $0' 命令执行。"
fi

if ! command -v rclone &> /dev/null; then
    error_exit "rclone 命令未找到。请先安装 rclone (https://rclone.org/install/)"
fi

if [ "$ACTUAL_BUCKET_NAME" == "your-actual-obs-bucket-name" ] || [ -z "$ACTUAL_BUCKET_NAME" ]; then
    error_exit "请在脚本中修改 'ACTUAL_BUCKET_NAME' 。"
fi

# 2. 创建本地临时目录
mkdir -p "$LOCAL_TEMP_STAGING_DIR/metadata"
if [ $? -ne 0 ]; then
    error_exit "无法创建本地临时目录 '$LOCAL_TEMP_STAGING_DIR/metadata'。"
fi

# 3. 生成元数据文件 (非关键步骤，失败只打印警告)
log_message "正在生成系统元数据文件..."
if ! dpkg --get-selections > "$LOCAL_TEMP_STAGING_DIR/metadata/pkglist_$(hostname)_$(date +%Y%m%d).txt" 2>/dev/null; then
    log_message "警告: 生成软件包列表失败 (可能非 Debian/Ubuntu 系统)，将继续执行。"
fi

crontab -u root -l > "$LOCAL_TEMP_STAGING_DIR/metadata/crontab_root_$(hostname)_$(date +%Y%m%d).txt" 2>/dev/null || \
    log_message "提示: root 用户没有 crontab 条目或读取失败。"

# 仅在 PRIMARY_USER 被定义且不为空时，才备份其 crontab
if [ -n "$PRIMARY_USER" ]; then
    if id "$PRIMARY_USER" &>/dev/null; then
        log_message "正在备份用户 '$PRIMARY_USER' 的 crontab..."
        crontab -u "$PRIMARY_USER" -l > "$LOCAL_TEMP_STAGING_DIR/metadata/crontab_${PRIMARY_USER}_$(hostname)_$(date +%Y%m%d).txt" 2>/dev/null || \
            log_message "提示: 用户 '$PRIMARY_USER' 没有 crontab 条目或读取失败。"
    else
        log_message "警告: 用户 '$PRIMARY_USER' 不存在，跳过其 crontab 备份。"
    fi
fi

#
# 定义要备份的源目录
#
SOURCES_TO_BACKUP=(
    "/root/"
    "/opt/"
)

# 仅在 PRIMARY_USER 被定义且不为空时，才将其家目录加入备份列表
if [ -n "$PRIMARY_USER" ]; then
    # 检查家目录是否存在，如果存在再加入列表
    if [ -d "/home/${PRIMARY_USER}" ]; then
        SOURCES_TO_BACKUP+=("/home/${PRIMARY_USER}/")
        log_message "主要用户已定义为 '$PRIMARY_USER'，其家目录 /home/${PRIMARY_USER}/ 已加入备份列表。"
    else
        log_message "警告: 用户 '$PRIMARY_USER' 的家目录 /home/${PRIMARY_USER}/ 不存在，将跳过。"
    fi
else
    log_message "提示: 未定义 PRIMARY_USER 或其为空，将跳过备份任何用户的家目录。"
fi

# 执行 rclone 同步，失败则立即退出
log_message "开始同步主目录... (任何同步失败将导致脚本中止)"
for SOURCE_DIR in "${SOURCES_TO_BACKUP[@]}"; do
    if [ ! -d "$SOURCE_DIR" ]; then
        log_message "警告: 本地目录 '$SOURCE_DIR' 不存在，跳过。"
        continue
    fi

    REMOTE_SUB_PATH=$(echo "$SOURCE_DIR" | sed 's#^/##; s#/$##')
    TARGET_PATH="${RCLONE_REMOTE_NAME}:${ACTUAL_BUCKET_NAME}/${REMOTE_FOLDER_INSIDE_BUCKET}/current/${REMOTE_SUB_PATH}"
    BACKUP_VERSION_DIR_REMOTE_PATH="${RCLONE_REMOTE_NAME}:${ACTUAL_BUCKET_NAME}/${REMOTE_FOLDER_INSIDE_BUCKET}/history/${REMOTE_SUB_PATH}"

    log_message "------------------------------------------------------------"
    log_message "正在同步: $SOURCE_DIR -> $TARGET_PATH"

    # 执行 rclone sync，并将 stderr 重定向到 stdout 以便在失败时完整捕获
    RCLONE_CMD_OUTPUT=$(rclone sync "$SOURCE_DIR" "$TARGET_PATH" \
        "${RCLONE_OPTS[@]}" \
        --backup-dir "$BACKUP_VERSION_DIR_REMOTE_PATH" \
        --suffix ".backup-$(date +%Y%m%d-%H%M%S)" \
        --suffix-keep-extension 2>&1)

    # 严格检查 rclone 的退出码
    if [ $? -ne 0 ]; then
        log_message "rclone 输出详情:"
        echo "$RCLONE_CMD_OUTPUT"
        error_exit "同步目录 '$SOURCE_DIR' 失败。请检查以上 rclone 输出以定位问题。"
    fi

    log_message "成功: '$SOURCE_DIR' 同步完成。"
done
log_message "------------------------------------------------------------"

#备份生成的元数据文件
log_message "正在同步生成的元数据文件..."
METADATA_SOURCE_DIR="$LOCAL_TEMP_STAGING_DIR/metadata/"
if [ -n "$(ls -A $METADATA_SOURCE_DIR 2>/dev/null)" ]; then
    METADATA_TARGET_PATH="${RCLONE_REMOTE_NAME}:${ACTUAL_BUCKET_NAME}/${REMOTE_FOLDER_INSIDE_BUCKET}/current/metadata_generated"
    METADATA_BACKUP_VERSION_DIR_REMOTE_PATH="${RCLONE_REMOTE_NAME}:${ACTUAL_BUCKET_NAME}/${REMOTE_FOLDER_INSIDE_BUCKET}/history/metadata_generated"

    RCLONE_CMD_OUTPUT_META=$(rclone sync "$METADATA_SOURCE_DIR" "$METADATA_TARGET_PATH" \
        "${RCLONE_OPTS[@]}" \
        --backup-dir "$METADATA_BACKUP_VERSION_DIR_REMOTE_PATH" \
        --suffix ".backup-$(date +%Y%m%d-%H%M%S)" \
        --suffix-keep-extension 2>&1)

    if [ $? -ne 0 ]; then
        log_message "rclone 输出详情:"
        echo "$RCLONE_CMD_OUTPUT_META"
        error_exit "同步元数据文件失败。"
    fi
    log_message "成功: 元数据文件同步完成。"
else
    log_message "提示: 没有找到生成的元数据文件，跳过同步。"
fi

log_message "备份成功完成，所有任务均已处理。"
exit 0
