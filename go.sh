#!/bin/bash
#
# New-API 交互式部署脚本
# 功能：配置管理、代码更新、Docker 部署、开机自启
#

set -e

# ==================== 常量定义 ====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.new-api-deploy"
CONFIG_FILE="$CONFIG_DIR/config.env"
COMPOSE_FILE="$CONFIG_DIR/docker-compose.yml"
SERVICE_NAME="new-api-deploy"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ==================== 工具函数 ====================
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

# 检查命令是否存在
check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "命令 '$1' 未安装，请先安装后再运行此脚本"
        exit 1
    fi
}

# 检查依赖
check_dependencies() {
    check_command git
    check_command docker
    if ! docker compose version &> /dev/null && ! docker-compose version &> /dev/null; then
        log_error "Docker Compose 未安装"
        exit 1
    fi
}

# 获取 docker compose 命令
get_compose_cmd() {
    if docker compose version &> /dev/null; then
        echo "docker compose"
    else
        echo "docker-compose"
    fi
}

# 生成随机字符串
generate_random_string() {
    local length=${1:-32}
    tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$length"
}

# 读取配置值（带默认值）
read_config_value() {
    local key=$1
    local default=$2
    if [[ -f "$CONFIG_FILE" ]]; then
        local value=$(grep "^${key}=" "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2-)
        # 去除首尾的单引号或双引号
        value="${value#\'}"
        value="${value%\'}"
        value="${value#\"}"
        value="${value%\"}"
        echo "${value:-$default}"
    else
        echo "$default"
    fi
}

# 交互式输入（带默认值）
prompt_input() {
    local prompt=$1
    local default=$2
    local var_name=$3
    local is_secret=${4:-false}
    
    if [[ "$is_secret" == "true" && -n "$default" ]]; then
        local display_default="[已配置]"
    else
        local display_default="$default"
    fi
    
    echo -ne "${BLUE}$prompt${NC}"
    if [[ -n "$display_default" ]]; then
        echo -ne " [${display_default}]: "
    else
        echo -ne ": "
    fi
    
    read -r input
    eval "$var_name=\"${input:-$default}\""
}

# 交互式确认
confirm() {
    local prompt=$1
    local default=${2:-n}
    
    if [[ "$default" == "y" ]]; then
        echo -ne "${YELLOW}$prompt [Y/n]: ${NC}"
    else
        echo -ne "${YELLOW}$prompt [y/N]: ${NC}"
    fi
    
    read -r response
    response=${response:-$default}
    [[ "$response" =~ ^[Yy]$ ]]
}

# ==================== 配置管理 ====================
init_config_dir() {
    if [[ ! -d "$CONFIG_DIR" ]]; then
        mkdir -p "$CONFIG_DIR"
        log_info "创建配置目录: $CONFIG_DIR"
    fi
}

# 检查是否已配置
is_configured() {
    [[ -f "$CONFIG_FILE" && -f "$COMPOSE_FILE" ]]
}

# 交互式配置
interactive_config() {
    local is_first_time=true
    if is_configured; then
        is_first_time=false
        echo ""
        log_warn "检测到已有配置，将进入修改模式（直接回车保留原值）"
    fi
    
    echo ""
    echo -e "${CYAN}==================== 基础配置 ====================${NC}"
    
    # 端口
    local current_port=$(read_config_value "PORT" "3000")
    prompt_input "服务端口" "$current_port" PORT
    
    # 数据目录
    local current_data_dir=$(read_config_value "DATA_DIR" "$CONFIG_DIR/data")
    prompt_input "数据目录" "$current_data_dir" DATA_DIR
    
    # 时区
    local current_tz=$(read_config_value "TZ" "Asia/Shanghai")
    prompt_input "时区" "$current_tz" TZ
    
    echo ""
    echo -e "${CYAN}==================== 数据库配置 ====================${NC}"
    
    # SQL DSN
    local current_sql_dsn=$(read_config_value "SQL_DSN" "")
    echo -e "${YELLOW}格式: user:password@tcp(host:port)/dbname?charset=utf8mb4&parseTime=True&loc=Local${NC}"
    prompt_input "MySQL 连接字符串 (SQL_DSN)" "$current_sql_dsn" SQL_DSN true
    
    if [[ -z "$SQL_DSN" ]]; then
        log_error "SQL_DSN 是必填项"
        exit 1
    fi
    
    echo ""
    echo -e "${CYAN}==================== Redis 配置 (可选) ====================${NC}"
    
    # Redis
    local current_redis=$(read_config_value "REDIS_CONN_STRING" "")
    echo -e "${YELLOW}格式: redis://:password@host:port/db 或留空不使用${NC}"
    prompt_input "Redis 连接字符串" "$current_redis" REDIS_CONN_STRING true
    
    echo ""
    echo -e "${CYAN}==================== 会话与安全配置 ====================${NC}"
    
    # Session Secret
    local current_session=$(read_config_value "SESSION_SECRET" "")
    local default_session=${current_session:-$(generate_random_string 32)}
    prompt_input "会话密钥 (多节点部署必填)" "$default_session" SESSION_SECRET true
    
    echo ""
    echo -e "${CYAN}==================== 性能配置 ====================${NC}"
    
    # 同步频率
    local current_sync=$(read_config_value "SYNC_FREQUENCY" "")
    prompt_input "数据库同步频率(秒，留空禁用)" "$current_sync" SYNC_FREQUENCY
    
    # 批量更新
    local current_batch=$(read_config_value "BATCH_UPDATE_ENABLED" "true")
    prompt_input "启用批量更新 (true/false)" "$current_batch" BATCH_UPDATE_ENABLED
    
    # 流超时
    local current_stream_timeout=$(read_config_value "STREAMING_TIMEOUT" "360")
    prompt_input "流模式超时时间(秒)" "$current_stream_timeout" STREAMING_TIMEOUT
    
    # 请求超时
    local current_relay_timeout=$(read_config_value "RELAY_TIMEOUT" "")
    prompt_input "请求超时时间(秒，0或留空不限制)" "$current_relay_timeout" RELAY_TIMEOUT
    
    # 内存缓存
    local current_mem_cache=$(read_config_value "MEMORY_CACHE_ENABLED" "")
    prompt_input "启用内存缓存 (true/false/留空)" "$current_mem_cache" MEMORY_CACHE_ENABLED
    
    echo ""
    echo -e "${CYAN}==================== 功能配置 (可选) ====================${NC}"
    
    # 错误日志
    local current_error_log=$(read_config_value "ERROR_LOG_ENABLED" "true")
    prompt_input "启用错误日志 (true/false)" "$current_error_log" ERROR_LOG_ENABLED
    
    # Gemini 图片数量
    local current_gemini=$(read_config_value "GEMINI_VISION_MAX_IMAGE_NUM" "")
    prompt_input "Gemini 最大图片数量 (留空使用默认)" "$current_gemini" GEMINI_VISION_MAX_IMAGE_NUM
    
    # 图片token统计
    local current_media_token=$(read_config_value "GET_MEDIA_TOKEN" "")
    prompt_input "统计图片Token (true/false/留空)" "$current_media_token" GET_MEDIA_TOKEN
    
    # 非流图片token
    local current_media_not_stream=$(read_config_value "GET_MEDIA_TOKEN_NOT_STREAM" "")
    prompt_input "非流模式统计图片Token (true/false/留空)" "$current_media_not_stream" GET_MEDIA_TOKEN_NOT_STREAM
    
    # Cohere 安全设置
    local current_cohere=$(read_config_value "COHERE_SAFETY_SETTING" "")
    prompt_input "Cohere 安全设置 (NONE/留空)" "$current_cohere" COHERE_SAFETY_SETTING
    
    # Dify 调试
    local current_dify=$(read_config_value "DIFY_DEBUG" "")
    prompt_input "Dify 调试模式 (true/false/留空)" "$current_dify" DIFY_DEBUG
    
    # 节点类型
    local current_node=$(read_config_value "NODE_TYPE" "")
    prompt_input "节点类型 (master/留空)" "$current_node" NODE_TYPE
    
    # 前端URL
    local current_frontend=$(read_config_value "FRONTEND_BASE_URL" "")
    prompt_input "前端基础URL (留空使用默认)" "$current_frontend" FRONTEND_BASE_URL
    
    # 保存配置
    save_config
    generate_compose_file
    
    # 创建数据目录
    mkdir -p "$DATA_DIR"
    
    echo ""
    log_info "配置已保存到: $CONFIG_FILE"
    
    return 0
}


# 保存配置到文件
save_config() {
    # 使用单引号包裹值，防止特殊字符被解析
    cat > "$CONFIG_FILE" << 'EOFHEADER'
# New-API 部署配置
EOFHEADER
    
    cat >> "$CONFIG_FILE" << EOF
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 项目目录: $SCRIPT_DIR

EOF
    
    # 写入配置值，使用单引号包裹防止特殊字符问题
    {
        echo "# 基础配置"
        echo "PORT='$PORT'"
        echo "DATA_DIR='$DATA_DIR'"
        echo "TZ='$TZ'"
        echo ""
        echo "# 数据库配置"
        echo "SQL_DSN='$SQL_DSN'"
        echo ""
        echo "# Redis配置"
        echo "REDIS_CONN_STRING='$REDIS_CONN_STRING'"
        echo ""
        echo "# 会话配置"
        echo "SESSION_SECRET='$SESSION_SECRET'"
        echo ""
        echo "# 性能配置"
        echo "SYNC_FREQUENCY='$SYNC_FREQUENCY'"
        echo "BATCH_UPDATE_ENABLED='$BATCH_UPDATE_ENABLED'"
        echo "STREAMING_TIMEOUT='$STREAMING_TIMEOUT'"
        echo "RELAY_TIMEOUT='$RELAY_TIMEOUT'"
        echo "MEMORY_CACHE_ENABLED='$MEMORY_CACHE_ENABLED'"
        echo ""
        echo "# 功能配置"
        echo "ERROR_LOG_ENABLED='$ERROR_LOG_ENABLED'"
        echo "GEMINI_VISION_MAX_IMAGE_NUM='$GEMINI_VISION_MAX_IMAGE_NUM'"
        echo "GET_MEDIA_TOKEN='$GET_MEDIA_TOKEN'"
        echo "GET_MEDIA_TOKEN_NOT_STREAM='$GET_MEDIA_TOKEN_NOT_STREAM'"
        echo "COHERE_SAFETY_SETTING='$COHERE_SAFETY_SETTING'"
        echo "DIFY_DEBUG='$DIFY_DEBUG'"
        echo "NODE_TYPE='$NODE_TYPE'"
        echo "FRONTEND_BASE_URL='$FRONTEND_BASE_URL'"
        echo ""
        echo "# 项目路径（用于更新代码）"
        echo "PROJECT_DIR='$SCRIPT_DIR'"
    } >> "$CONFIG_FILE"
    
    chmod 600 "$CONFIG_FILE"
}

# 加载配置（安全方式，不使用 source）
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        return 1
    fi
    
    while IFS='=' read -r key value; do
        # 跳过注释和空行
        [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
        # 去除首尾空格
        key=$(echo "$key" | xargs)
        # 去除值的首尾引号
        value="${value#\'}"
        value="${value%\'}"
        value="${value#\"}"
        value="${value%\"}"
        # 导出变量
        export "$key=$value"
    done < "$CONFIG_FILE"
    
    return 0
}

# 生成 docker-compose.yml
generate_compose_file() {
    load_config
    
    # 构建环境变量部分，只包含非空值
    local env_vars=""
    
    add_env() {
        local key=$1
        local value=$2
        if [[ -n "$value" ]]; then
            env_vars="${env_vars}      - ${key}=${value}\n"
        fi
    }
    
    add_env "PORT" "$PORT"
    add_env "SQL_DSN" "$SQL_DSN"
    add_env "REDIS_CONN_STRING" "$REDIS_CONN_STRING"
    add_env "TZ" "$TZ"
    add_env "SESSION_SECRET" "$SESSION_SECRET"
    add_env "SYNC_FREQUENCY" "$SYNC_FREQUENCY"
    add_env "BATCH_UPDATE_ENABLED" "$BATCH_UPDATE_ENABLED"
    add_env "STREAMING_TIMEOUT" "$STREAMING_TIMEOUT"
    add_env "RELAY_TIMEOUT" "$RELAY_TIMEOUT"
    add_env "MEMORY_CACHE_ENABLED" "$MEMORY_CACHE_ENABLED"
    add_env "ERROR_LOG_ENABLED" "$ERROR_LOG_ENABLED"
    add_env "GEMINI_VISION_MAX_IMAGE_NUM" "$GEMINI_VISION_MAX_IMAGE_NUM"
    add_env "GET_MEDIA_TOKEN" "$GET_MEDIA_TOKEN"
    add_env "GET_MEDIA_TOKEN_NOT_STREAM" "$GET_MEDIA_TOKEN_NOT_STREAM"
    add_env "COHERE_SAFETY_SETTING" "$COHERE_SAFETY_SETTING"
    add_env "DIFY_DEBUG" "$DIFY_DEBUG"
    add_env "NODE_TYPE" "$NODE_TYPE"
    add_env "FRONTEND_BASE_URL" "$FRONTEND_BASE_URL"
    
    cat > "$COMPOSE_FILE" << EOF
# New-API Docker Compose 部署配置
# 自动生成，请勿手动修改
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 修改配置请运行: $SCRIPT_DIR/go.sh config

services:
  new-api:
    image: new-api:local
    container_name: new-api
    restart: always
    network_mode: host
    command: --log-dir /app/logs
    volumes:
      - ${DATA_DIR}/data:/data
      - ${DATA_DIR}/logs:/app/logs
    environment:
$(echo -e "$env_vars" | sed '/^$/d')
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O - http://localhost:3000/api/status | grep -o '\"success\":.*true' || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
EOF
    
    log_info "Docker Compose 配置已生成: $COMPOSE_FILE"
}

# ==================== Git 操作 ====================
update_code() {
    log_step "更新代码..."
    
    cd "$SCRIPT_DIR"
    
    # 获取当前分支
    local current_branch=$(git rev-parse --abbrev-ref HEAD)
    log_info "当前分支: $current_branch"
    
    # 获取更新前的 commit
    local old_commit=$(git rev-parse --short HEAD)
    
    # 强制同步远程代码
    log_info "拉取远程更新..."
    git fetch --all --prune
    
    # 强制重置到远程分支
    git reset --hard "origin/$current_branch"
    
    # 获取更新后的 commit
    local new_commit=$(git rev-parse --short HEAD)
    
    if [[ "$old_commit" == "$new_commit" ]]; then
        log_info "代码已是最新 ($new_commit)"
    else
        log_info "代码已更新: $old_commit -> $new_commit"
    fi
}

# ==================== Docker 操作 ====================
deploy() {
    local compose_cmd=$(get_compose_cmd)
    
    if ! is_configured; then
        log_error "尚未配置，请先运行配置"
        interactive_config
    fi
    
    load_config
    
    echo ""
    log_step "开始部署..."
    
    # 1. 更新代码
    update_code
    
    # 2. 记录旧镜像ID（用于后续清理）
    local old_image_id=$(docker images -q new-api:local 2>/dev/null)
    
    # 3. 构建新镜像
    log_step "构建新镜像..."
    cd "$SCRIPT_DIR"
    docker build -t new-api:local .
    
    if [[ $? -ne 0 ]]; then
        log_error "镜像构建失败"
        exit 1
    fi
    
    # 4. 停止旧容器
    log_step "停止旧容器..."
    $compose_cmd -f "$COMPOSE_FILE" down --remove-orphans 2>/dev/null || true
    
    # 5. 清理日志
    log_step "清理历史日志..."
    rm -rf "${DATA_DIR}/logs"/* 2>/dev/null || true
    
    # 6. 启动新容器
    log_step "启动新容器..."
    $compose_cmd -f "$COMPOSE_FILE" up -d
    
    # 7. 清理旧镜像
    if [[ -n "$old_image_id" ]]; then
        local new_image_id=$(docker images -q new-api:local 2>/dev/null)
        if [[ "$old_image_id" != "$new_image_id" ]]; then
            log_step "清理旧镜像..."
            docker rmi "$old_image_id" 2>/dev/null || true
        fi
    fi
    docker image prune -f
    
    # 8. 检查状态
    sleep 3
    show_status
    
    echo ""
    log_info "部署完成！"
}

# 快速更新（不重新配置）
quick_update() {
    local compose_cmd=$(get_compose_cmd)
    
    if ! is_configured; then
        log_error "尚未配置，请先运行: $0 config"
        exit 1
    fi
    
    load_config
    
    log_step "快速更新..."
    
    # 1. 更新代码
    update_code
    
    # 重新生成 compose 文件（以防模板有更新）
    generate_compose_file
    
    # 2. 记录旧镜像ID
    local old_image_id=$(docker images -q new-api:local 2>/dev/null)
    
    # 3. 构建新镜像
    log_step "构建新镜像..."
    cd "$SCRIPT_DIR"
    docker build -t new-api:local .
    
    if [[ $? -ne 0 ]]; then
        log_error "镜像构建失败"
        exit 1
    fi
    
    # 4. 停止旧容器
    log_step "停止旧容器..."
    $compose_cmd -f "$COMPOSE_FILE" down --remove-orphans 2>/dev/null || true
    
    # 5. 清理日志
    log_step "清理历史日志..."
    rm -rf "${DATA_DIR}/logs"/* 2>/dev/null || true
    
    # 6. 启动新容器
    log_step "启动新容器..."
    $compose_cmd -f "$COMPOSE_FILE" up -d
    
    # 7. 清理旧镜像
    if [[ -n "$old_image_id" ]]; then
        local new_image_id=$(docker images -q new-api:local 2>/dev/null)
        if [[ "$old_image_id" != "$new_image_id" ]]; then
            log_step "清理旧镜像..."
            docker rmi "$old_image_id" 2>/dev/null || true
        fi
    fi
    docker image prune -f
    
    # 8. 检查状态
    sleep 3
    show_status
    
    log_info "更新完成！"
}

# 显示状态
show_status() {
    local compose_cmd=$(get_compose_cmd)
    
    echo ""
    echo -e "${CYAN}==================== 服务状态 ====================${NC}"
    
    if [[ -f "$COMPOSE_FILE" ]]; then
        $compose_cmd -f "$COMPOSE_FILE" ps
    else
        docker ps --filter "name=new-api" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    fi
}

# 查看日志
show_logs() {
    local compose_cmd=$(get_compose_cmd)
    local lines=${1:-100}
    
    if [[ -f "$COMPOSE_FILE" ]]; then
        $compose_cmd -f "$COMPOSE_FILE" logs --tail "$lines" -f
    else
        docker logs --tail "$lines" -f new-api
    fi
}

# 停止服务
stop_service() {
    local compose_cmd=$(get_compose_cmd)
    
    log_step "停止服务..."
    if [[ -f "$COMPOSE_FILE" ]]; then
        $compose_cmd -f "$COMPOSE_FILE" down
    else
        docker stop new-api 2>/dev/null || true
        docker rm new-api 2>/dev/null || true
    fi
    log_info "服务已停止"
}

# 重启服务
restart_service() {
    local compose_cmd=$(get_compose_cmd)
    
    log_step "重启服务..."
    if [[ -f "$COMPOSE_FILE" ]]; then
        $compose_cmd -f "$COMPOSE_FILE" restart
    else
        docker restart new-api
    fi
    
    sleep 3
    show_status
    log_info "服务已重启"
}


# ==================== Systemd 服务管理 ====================
install_systemd_service() {
    if [[ $EUID -ne 0 ]]; then
        log_warn "安装 systemd 服务需要 root 权限"
        log_info "请使用 sudo 运行: sudo $0 install-service"
        return 1
    fi
    
    if ! is_configured; then
        log_error "请先完成配置再安装服务"
        return 1
    fi
    
    load_config
    
    local compose_cmd=$(get_compose_cmd)
    
    log_step "安装 systemd 服务..."
    
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=New-API Docker Compose Service
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$CONFIG_DIR
ExecStart=$compose_cmd -f $COMPOSE_FILE up -d
ExecStop=$compose_cmd -f $COMPOSE_FILE down
ExecReload=$compose_cmd -f $COMPOSE_FILE pull && $compose_cmd -f $COMPOSE_FILE up -d
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF
    
    # 重载 systemd
    systemctl daemon-reload
    
    # 启用开机自启
    systemctl enable "$SERVICE_NAME"
    
    log_info "Systemd 服务已安装并启用开机自启"
    log_info "服务名称: $SERVICE_NAME"
    echo ""
    echo "可用命令:"
    echo "  systemctl status $SERVICE_NAME   # 查看状态"
    echo "  systemctl restart $SERVICE_NAME  # 重启服务"
    echo "  systemctl stop $SERVICE_NAME     # 停止服务"
    echo "  systemctl disable $SERVICE_NAME  # 禁用开机自启"
}

uninstall_systemd_service() {
    if [[ $EUID -ne 0 ]]; then
        log_warn "卸载 systemd 服务需要 root 权限"
        return 1
    fi
    
    log_step "卸载 systemd 服务..."
    
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    
    log_info "Systemd 服务已卸载"
}

# ==================== 主菜单 ====================
show_menu() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         New-API 交互式部署工具                     ║${NC}"
    echo -e "${CYAN}╠════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}  1. 配置/修改配置                                  ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  2. 部署/更新服务 (拉取代码+重新部署)              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  3. 快速更新 (仅更新代码和镜像)                    ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  4. 查看服务状态                                   ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  5. 查看日志                                       ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  6. 重启服务                                       ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  7. 停止服务                                       ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  8. 安装开机自启 (需要sudo)                        ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  9. 卸载开机自启 (需要sudo)                        ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  0. 退出                                           ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════╝${NC}"
    
    if is_configured; then
        echo -e "${GREEN}[已配置]${NC} 配置文件: $CONFIG_FILE"
    else
        echo -e "${YELLOW}[未配置]${NC} 请先进行配置"
    fi
    echo ""
}

interactive_menu() {
    while true; do
        show_menu
        echo -ne "${BLUE}请选择操作 [0-9]: ${NC}"
        read -r choice
        
        case $choice in
            1) interactive_config ;;
            2) deploy ;;
            3) quick_update ;;
            4) show_status ;;
            5) show_logs ;;
            6) restart_service ;;
            7) stop_service ;;
            8) install_systemd_service ;;
            9) uninstall_systemd_service ;;
            0) 
                echo "再见！"
                exit 0 
                ;;
            *)
                log_warn "无效选择，请重新输入"
                ;;
        esac
        
        echo ""
        echo -ne "${YELLOW}按回车键继续...${NC}"
        read -r
    done
}

# ==================== 命令行参数处理 ====================
show_help() {
    echo "用法: $0 [命令]"
    echo ""
    echo "命令:"
    echo "  (无参数)        交互式菜单"
    echo "  config          配置/修改配置"
    echo "  deploy          部署/更新服务"
    echo "  update          快速更新"
    echo "  status          查看服务状态"
    echo "  logs [行数]     查看日志 (默认100行)"
    echo "  restart         重启服务"
    echo "  stop            停止服务"
    echo "  install-service 安装开机自启 (需要sudo)"
    echo "  remove-service  卸载开机自启 (需要sudo)"
    echo "  help            显示此帮助"
    echo ""
    echo "示例:"
    echo "  $0              # 进入交互式菜单"
    echo "  $0 deploy       # 直接部署"
    echo "  $0 logs 200     # 查看最近200行日志"
    echo "  sudo $0 install-service  # 安装开机自启"
}

# ==================== 主入口 ====================
main() {
    # 初始化
    init_config_dir
    check_dependencies
    
    # 处理命令行参数
    case "${1:-}" in
        "")
            interactive_menu
            ;;
        config)
            interactive_config
            ;;
        deploy)
            deploy
            ;;
        update)
            quick_update
            ;;
        status)
            show_status
            ;;
        logs)
            show_logs "${2:-100}"
            ;;
        restart)
            restart_service
            ;;
        stop)
            stop_service
            ;;
        install-service)
            install_systemd_service
            ;;
        remove-service)
            uninstall_systemd_service
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "未知命令: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
