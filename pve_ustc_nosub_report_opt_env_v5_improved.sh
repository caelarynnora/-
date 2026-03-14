#!/bin/bash
# ============================================================================== 
# 脚本名称: pve_ustc_nosub_report_opt_env_v5_improved.sh
# 适用版本: PVE 7-9 宿主机 (当前时间: 2026-03-14)
# 版本: v5 (改进版)
# 功能: 根据网络环境智能选择镜像源 + 永久去订阅 + 改前/改后报告
# 改进点: 安全加固 + 代码复用 + 容错能力 + 回滚支持
# ============================================================================== 

set -Eeuo pipefail

# ============================================================================
# 版本信息和配置常量
# ============================================================================
SCRIPT_VERSION="5.0"
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 配置路径
LOG_FILE="/var/log/pve-init.log"
LOCK_FILE="/var/run/pve-init.lock"
BACKUP_BASE_DIR="/etc/apt/sources.list.d/backups"
TOOLS_DIR="/opt/pve-tools"
STATE_FILE="/var/lib/pve-init.state"

# ============================================================================
# 颜色定义
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================================
# 全局变量
# ============================================================================
declare -A BEFORE
declare -A AFTER
declare -A CONFIG
ENV=""
PVE_VERSION=""
PVE_MAJOR=""
DRY_RUN=0

# ============================================================================
# 日志函数 - 增强版
# ============================================================================
init_log() {
    local log_dir
    log_dir=$(dirname "$LOG_FILE")
    
    if ! mkdir -p "$log_dir" 2>/dev/null; then
        LOG_FILE="/tmp/pve-init.log"
        echo "警告: 无法创建 $log_dir，使用 $LOG_FILE"
    fi
    
    # 设置日志文件权限
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/pve-init.log"
    chmod 644 "$LOG_FILE" 2>/dev/null || true
}

log_info()  { echo -e "$(date '+%F %T') ${GREEN}[INFO]${NC} $*" | tee -a "$LOG_FILE"; }
log_warn()  { echo -e "$(date '+%F %T') ${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"; }
log_error() { echo -e "$(date '+%F %T') ${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; }
log_step()  { echo -e "$(date '+%F %T') ${BLUE}[STEP]${NC} $*" | tee -a "$LOG_FILE"; }
log_success() { echo -e "$(date '+%F %T') ${CYAN}[SUCCESS]${NC} $*" | tee -a "$LOG_FILE"; }

# ============================================================================
# 通用命令执行和错误处理
# ============================================================================
run_cmd() {
    local cmd_output
    if [ $DRY_RUN -eq 1 ]; then
        log_info "[DRY-RUN] 将执行: $*"
        return 0
    fi
    
    if ! cmd_output="$("$@" 2>&1); then
        log_error "命令失败: $* (退出码 $?)"
        log_error "输出: $cmd_output"
        return 1
    fi
    return 0
}

require_cmd() {
    local missing=0
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "缺少必要命令: $cmd"
            missing=$((missing + 1))
        fi
    done
    
    if [ $missing -gt 0 ]; then
        log_error "缺少 $missing 个必要命令，请先安装"
        exit 1
    fi
}

# ============================================================================
# 系统检测函数
# ============================================================================
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 root 权限运行此脚本"
        exit 1
    fi
    log_info "✓ root 权限检测通过"
}

check_network() {
    log_info "检测网络连通性..."
    if ! ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
        log_warn "网络暂不可用，某些功能可能受限"
        return 1
    fi
    log_info "✓ 网络连通性正常"
    return 0
}

verify_pve_env() {
    log_info "检测 PVE 环境..."
    
    if [ -f /etc/pve/.version ]; then
        PVE_VERSION=$(cat /etc/pve/.version)
        PVE_MAJOR=$(echo "$PVE_VERSION" | cut -d. -f1)
        log_info "✓ 检测到 PVE 版本: $PVE_VERSION"
        
        if [[ "$PVE_MAJOR" -lt 7 || "$PVE_MAJOR" -gt 10 ]]; then
            log_warn "脚本主要针对 PVE 7-10 版本，继续可能存在风险"
        fi
    else
        log_warn "未检测到 PVE 环境，继续执行"
        PVE_VERSION="未检测"
        PVE_MAJOR="0"
    fi
}

check_commands() {
    log_info "检测必要命令..."
    require_cmd wget apt tee cp mv sed systemctl grep awk lsblk ip uname lsb_release curl
    log_info "✓ 必要命令检测通过"
}

setup_trap() {
    log_info "设置错误处理陷阱..."
    trap 'cleanup_on_exit' EXIT INT TERM
}

cleanup_on_exit() {
    local exit_code=$?
    
    # 清理锁文件
    if [ -f "$LOCK_FILE" ]; then
        rm -f "$LOCK_FILE" || true
    fi
    
    if [ $exit_code -eq 0 ]; then
        log_success "脚本执行成功"
    else
        log_error "脚本执行失败 (退出码: $exit_code)"
    fi
    
    exit $exit_code
}

# ============================================================================
# 锁文件管理
# ============================================================================
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if kill -0 "$pid" 2>/dev/null; then
            log_error "脚本已经在运行中 (PID: $pid)"
            exit 1
        else
            log_warn "清理过期的锁文件"
            rm -f "$LOCK_FILE"
        fi
    fi
    
    echo $$ > "$LOCK_FILE"
    log_info "✓ 获取执行锁"
}

# ============================================================================
# 网络环境检测和镜像源选择
# ============================================================================
test_mirror_speed() {
    local url="$1"
    local timeout=5
    local time_taken
    
    time_taken=$(curl -s --max-time "$timeout" -o /dev/null -w "%{time_total}" "$url" 2>/dev/null || echo "999")
    echo "$time_taken"
}

detect_environment() {
    log_step "检测网络环境，选择最快镜像源..."
    
    local time_ustc time_debian
    
    # 测试国内镜像延迟
    log_info "测试国内镜像源延迟..."
    time_ustc=$(test_mirror_speed "https://mirrors.ustc.edu.cn/debian/dists/bookworm/InRelease")
    
    # 测试国外官方源延迟
    log_info "测试国外官方源延迟..."
    time_debian=$(test_mirror_speed "https://deb.debian.org/debian/dists/bookworm/InRelease")
    
    log_info "延迟对比 - USTC: ${time_ustc}s, Debian官方: ${time_debian}s"
    
    # 比较（避免浮点数比较问题）
    if [ "$time_ustc" = "999" ] && [ "$time_debian" = "999" ]; then
        ENV="domestic"
        log_warn "网络检测失败，默认使用国内镜像源"
    else
        # 移除浮点数后进行比较
        local ustc_int debian_int
        ustc_int=$(printf "%.0f" "$time_ustc" 2>/dev/null || echo "999")
        debian_int=$(printf "%.0f" "$time_debian" 2>/dev/null || echo "999")
        
        if [ "$ustc_int" -lt "$debian_int" ]; then
            ENV="domestic"
            log_success "判断为国内环境，使用国内镜像源"
        else
            ENV="foreign"
            log_success "判断为国外环境，使用官方源"
        fi
    fi
}

# ============================================================================
# Debian codename 映射
# ============================================================================
get_debian_codename() {
    local codename
    case "$PVE_MAJOR" in
        7)
            codename="bullseye"
            ;;
        8)
            codename="bookworm"
            ;;
        9|10)
            codename="trixie"
            ;;
        *)
            log_error "不支持的 PVE 主版本: $PVE_MAJOR"
            return 1
            ;;
    esac
    echo "$codename"
}

# ============================================================================
# 镜像源 URL 配置生成
# ============================================================================
get_debian_source() {
    local codename
    codename=$(get_debian_codename) || return 1
    
    if [ "$ENV" = "domestic" ]; then
        cat <<EOF
Types: deb deb-src
URIs: https://mirrors.ustc.edu.cn/debian/
Suites: $codename $codename-updates $codename-backports
Components: main non-free non-free-firmware contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb deb-src
URIs: https://mirrors.ustc.edu.cn/debian-security/
Suites: $codename-security
Components: main non-free non-free-firmware contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
    else
        cat <<EOF
Types: deb deb-src
URIs: https://deb.debian.org/debian
Suites: $codename $codename-updates $codename-backports
Components: main non-free non-free-firmware contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb deb-src
URIs: https://security.debian.org/debian-security
Suites: $codename-security
Components: main non-free non-free-firmware contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
    fi
}

get_pve_source() {
    local codename
    codename=$(get_debian_codename) || return 1
    
    if [ "$ENV" = "domestic" ]; then
        cat <<EOF
Types: deb
URIs: https://mirrors.ustc.edu.cn/proxmox/debian/pve
Suites: $codename
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    else
        cat <<EOF
Types: deb
URIs: https://download.proxmox.com/debian/pve
Suites: $codename
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    fi
}

get_ceph_source() {
    local codename
    codename=$(get_debian_codename) || return 1
    
    if [ "$ENV" = "domestic" ]; then
        cat <<EOF
Types: deb
URIs: https://mirrors.ustc.edu.cn/proxmox/debian/ceph-squid
Suites: $codename
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    else
        cat <<EOF
Types: deb
URIs: https://download.proxmox.com/debian/ceph-squid
Suites: $codename
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    fi
}

# ============================================================================
# 备份函数 - 增强版
# ============================================================================
backup_sources() {
    log_step "备份原有 APT 源..."
    
    local backup_dir
    backup_dir="${BACKUP_BASE_DIR}/backup_$(date '+%Y%m%d_%H%M%S')"
    
    if ! mkdir -p "$backup_dir"; then
        log_error "创建备份目录失败: $backup_dir"
        return 1
    fi
    
    local file_count=0
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources 2>/dev/null; do
        if [ -f "$f" ]; then
            if cp "$f" "$backup_dir/" 2>/dev/null; then
                log_info "✓ 备份: $(basename "$f")"
                file_count=$((file_count + 1))
            fi
        fi
    done
    
    if [ $file_count -eq 0 ]; then
        log_warn "未找到需要备份的源文件"
    fi
    
    # 清理旧备份（保留最近5个）
    cleanup_old_backups 5
    
    log_success "备份完成: $backup_dir"
}

cleanup_old_backups() {
    local keep_count=${1:-5}
    local old_backups
    
    old_backups=$(ls -1td "${BACKUP_BASE_DIR}"/backup_* 2>/dev/null | tail -n +$((keep_count + 1))) || true
    
    if [ -n "$old_backups" ]; then
        log_info "清理旧备份，保留最近 $keep_count 个..."
        echo "$old_backups" | xargs -r rm -rf || log_warn "清理旧备份时出现错误"
    fi
}

# ============================================================================
# 源文件管理 - 增强版
# ============================================================================
write_source_file() {
    local file="$1"
    local content="$2"
    
    if [ $DRY_RUN -eq 1 ]; then
        log_info "[DRY-RUN] 将写入文件: $file"
        log_info "[DRY-RUN] 内容预览:"
        echo "$content" | sed 's/^/  /'
        return 0
    fi
    
    local file_dir
    file_dir=$(dirname "$file")
    
    if ! mkdir -p "$file_dir"; then
        log_error "创建目录失败: $file_dir"
        return 1
    fi
    
    if echo "$content" > "$file"; then
        chmod 644 "$file"
        log_success "✓ 已写入源文件: $(basename "$file")"
        return 0
    else
        log_error "写入源文件失败: $file"
        return 1
    fi
}

setup_debian_sources() {
    log_step "配置 Debian 基础系统源..."
    local content
    content=$(get_debian_source) || return 1
    write_source_file "/etc/apt/sources.list.d/debian.sources" "$content"
}

setup_pve_sources() {
    log_step "配置 PVE 无订阅源..."
    local content
    content=$(get_pve_source) || return 1
    write_source_file "/etc/apt/sources.list.d/pve-no-subscription.sources" "$content"
}

setup_ceph_sources() {
    log_step "配置 Ceph 无订阅源..."
    local content
    content=$(get_ceph_source) || return 1
    write_source_file "/etc/apt/sources.list.d/ceph-no-subscription.sources" "$content"
}

disable_enterprise_sources() {
    log_step "禁用企业订阅源..."
    
    local files=(
        "/etc/apt/sources.list.d/pve-enterprise.sources"
        "/etc/apt/sources.list.d/ceph-enterprise.sources"
        "/etc/apt/sources.list.d/pve-enterprise.list"
        "/etc/apt/sources.list.d/ceph.list"
    )
    
    for file in "${files[@]}"; do
        if [ -f "$file" ]; then
            if [ $DRY_RUN -eq 1 ]; then
                log_info "[DRY-RUN] 将禁用: $(basename "$file")"
            else
                if mv "$file" "${file}.disabled"; then
                    log_success "✓ 已禁用: $(basename "$file")"
                fi
            fi
        fi
    done
}

# ============================================================================
# GPG 密钥管理 - 安全加固版
# ============================================================================
download_proxmox_gpg() {
    local codename
    codename=$(get_debian_codename) || return 1
    
    local gpg_url
    if [ "$ENV" = "domestic" ]; then
        gpg_url="https://mirrors.ustc.edu.cn/proxmox/debian/proxmox-release-${codename}.gpg"
    else
        gpg_url="https://enterprise.proxmox.com/debian/proxmox-release-${codename}.gpg"
    fi
    
    local gpg_file="/usr/share/keyrings/proxmox-archive-keyring.gpg"
    
    if [ -f "$gpg_file" ]; then
        log_info "GPG 密钥已存在，跳过下载"
        return 0
    fi
    
    log_info "下载 Proxmox GPG 密钥: $gpg_url"
    
    if [ $DRY_RUN -eq 1 ]; then
        log_info "[DRY-RUN] 将下载 GPG 密钥"
        return 0
    fi
    
    local temp_gpg
    temp_gpg=$(mktemp)
    trap "rm -f '$temp_gpg'" RETURN
    
    if ! wget --check-certificate=on -q -O "$temp_gpg" "$gpg_url"; then
        log_error "GPG 密钥下载失败"
        return 1
    fi
    
    # 验证下载的文件是否为有效的 GPG 密钥
    if ! gpg --with-colons --list-keys --keyring "$temp_gpg" >/dev/null 2>&1; then
        log_error "下载的 GPG 密钥无效"
        return 1
    fi
    
    if cp "$temp_gpg" "$gpg_file"; then
        chmod 644 "$gpg_file"
        log_success "✓ GPG 密钥已安装"
        return 0
    else
        log_error "安装 GPG 密钥失败"
        return 1
    fi
}

update_apt_cache() {
    log_step "更新 APT 缓存..."
    
    if ! download_proxmox_gpg; then
        log_error "GPG 密钥安装失败，无法继续"
        return 1
    fi
    
    if [ $DRY_RUN -eq 1 ]; then
        log_info "[DRY-RUN] 将执行 apt update"
        return 0
    fi
    
    if run_cmd apt update -y; then
        log_success "✓ APT 缓存已更新"
        return 0
    else
        log_error "APT 缓存更新失败"
        return 1
    fi
}

# ============================================================================
# Subscription 管理函数 - 抽取复用
# ============================================================================
generate_fake_subscription() {
    cat <<'EOF'
{
 "status": "Active",
 "level": "Community",
 "key": "pve-fake-key",
 "nextduedate": 9999999999
}
EOF
}

write_fake_subscription() {
    local file="$1"
    local content
    content=$(generate_fake_subscription)
    
    if [ $DRY_RUN -eq 1 ]; then
        log_info "[DRY-RUN] 将创建 Fake subscription: $file"
        return 0
    fi
    
    local file_dir
    file_dir=$(dirname "$file")
    mkdir -p "$file_dir"
    
    echo "$content" > "$file"
    chmod 644 "$file"
    chown root:root "$file"
    
    log_success "✓ Fake subscription 已创建: $file"
}

patch_subscription_immediate() {
    log_step "立即应用 Fake subscription..."
    
    write_fake_subscription "/etc/pve/subscription" || return 1
    
    if [ $DRY_RUN -eq 0 ]; then
        if systemctl restart pveproxy 2>/dev/null; then
            log_success "✓ pveproxy 已重启"
        else
            log_warn "pveproxy 重启失败或未安装"
        fi
    fi
}

# ============================================================================
# 持久化补丁机制
# ============================================================================
setup_persistent_patch() {
    log_step "配置持久化 Fake subscription 机制..."
    
    if [ $DRY_RUN -eq 1 ]; then
        log_info "[DRY-RUN] 将创建持久化服务"
        return 0
    fi
    
    # 创建补丁脚本
    mkdir -p "$TOOLS_DIR"
    
    cat > "$TOOLS_DIR/patch-nosub.sh" <<'PATCH_EOF'
#!/bin/bash
SUBSCRIPTION_FILE="/etc/pve/subscription"
LOG_FILE="/var/log/pve-nosub-patcher.log"

log_msg() {
    echo "[0;32m$(date '+%F %T') $*\u001b[0m" >> "$LOG_FILE"
}

if [ ! -f "$SUBSCRIPTION_FILE" ] || ! grep -q '"status": "Active"' "$SUBSCRIPTION_FILE" 2>/dev/null; then
    cat > "$SUBSCRIPTION_FILE" <<'NOSUB_EOF'
{
 "status": "Active",
 "level": "Community",
 "key": "pve-fake-key",
 "nextduedate": 9999999999
}
NOSUB_EOF
    chmod 644 "$SUBSCRIPTION_FILE"
    chown root:root "$SUBSCRIPTION_FILE"
    
    # 尝试重启 pveproxy
    if systemctl is-active pveproxy >/dev/null 2>&1; then
        systemctl restart pveproxy || log_msg "pveproxy 重启失败"
    fi
    
    log_msg "已应用 Fake subscription"
else
    log_msg "Fake subscription 已存在，无需修改"
fi
PATCH_EOF
    
    chmod +x "$TOOLS_DIR/patch-nosub.sh"
    log_success "✓ 补丁脚本已创建"
    
    # 创建 systemd 服务
    cat > /etc/systemd/system/pve-nosub-patcher.service <<'SERVICE_EOF'
[Unit]
Description=PVE No-Subscription Notice Patcher
Documentation=man:systemctl(1)
After=pveproxy.service
ConditionPathExists=/etc/pve

[Service]
Type=oneshot
ExecStart=/opt/pve-tools/patch-nosub.sh
RemainAfterExit=yes
Restart=on-failure
RestartSec=300
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE_EOF
    
    log_success "✓ systemd 服务已创建"
    
    # 创建 APT 后置处理钩子
    cat > /etc/apt/apt.conf.d/99-pve-nosub <<'APT_EOF'
DPkg::Post-Invoke {"/opt/pve-tools/patch-nosub.sh || true";};
APT_EOF
    
    log_success "✓ APT 后置处理钩子已创建"
    
    # 启用并启动服务
    systemctl daemon-reload
    systemctl enable pve-nosub-patcher.service
    systemctl start pve-nosub-patcher.service
    
    log_success "✓ 持久化机制已启用"
}

# ============================================================================
# 系统状态快照
# ============================================================================
snapshot_system_state() {
    local state_var=$1
    
    log_info "采集系统状态..."
    
    eval "[0;36m${state_var}[pve]=[0;36m\\$(pveversion 2>/dev/null || echo '未安装')"
    eval "[0;36m${state_var}[debian]=[0;36m\\$(lsb_release -cs 2>/dev/null || echo '未检测')"
    eval "[0;36m${state_var}[kernel]=[0;36m\\$(uname -r)"
    eval "[0;36m${state_var}[subscription]=[0;36m\\$(cat /etc/pve/subscription 2>/dev/null | head -c 100 || echo '未配置')"
    
    local sources
    sources=$(grep -h 'URIs:' /etc/apt/sources.list.d/*.sources 2>/dev/null | sort -u | tr '\n' '|')
    eval "[0;36m${state_var}[sources]=[0;36m\\$(echo "${sources:-'未配置'}")"
}

snapshot_before() {
    log_step "采集改前系统状态..."
    snapshot_system_state "BEFORE"
}

snapshot_after() {
    log_step "采集改后系统状态..."
    snapshot_system_state "AFTER"
}

# ============================================================================
# 报告生成
# ============================================================================
generate_diff_report() {
    local report_file="/var/log/pve-init-report.txt"
    local report_timestamp
    report_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    {
        echo "========================================"
        echo "       PVE 配置改前 / 改后对比报告"
        echo "========================================"
        echo "报告时间       : $report_timestamp"
        echo "脚本版本       : $SCRIPT_VERSION"
        echo "网络环境       : $ENV"
        echo ""
        echo "【系统信息对比】"
        echo "PVE 版本"
        echo "  改前: [0;36m"];${BEFORE[pve];}[0m"
        echo "  改后: [0;36m"];${AFTER[pve];}[0m"
        echo ""
        echo "Debian 版本"
        echo "  改前: [0;36m"];${BEFORE[debian];}[0m"
        echo "  改后: [0;36m"];${AFTER[debian];}[0m"
        echo ""
        echo "Linux 内核"
        echo "  改前: [0;36m"];${BEFORE[kernel];}[0m"
        echo "  改后: [0;36m"];${AFTER[kernel];}[0m"
        echo ""
        echo "【订阅状态对比】"
        echo "  改前: [0;36m"];${BEFORE[subscription];}[0m"
        echo "  改后: [0;36m"];${AFTER[subscription];}[0m"
        echo ""
        echo "【镜像源对比】"
        echo "  改前: [0;36m"];${BEFORE[sources];}[0m"
        echo "  改后: [0;36m"];${AFTER[sources];}[0m"
        echo ""
        echo "【操作概览】"
        echo "✓ 备份位置: $BACKUP_BASE_DIR"
        echo "✓ 工具位置: $TOOLS_DIR"
        echo "✓ 日志位置: $LOG_FILE"
        echo ""
        echo "========================================"
        echo "【回滚说明】"
        echo "若需要回滚到之前的配置，执行:"
        echo "  sudo cp -r $BACKUP_BASE_DIR/backup_YYYYMMDD_HHMMSS/* /etc/apt/"
        echo "  sudo apt update"
        echo "========================================"
    } | tee "$report_file"
    
    log_success "报告已保存: $report_file"
}

# ============================================================================
# 验证函数
# ============================================================================
verify_configuration() {
    log_step "验证配置..."
    
    local checks_passed=0
    local checks_total=0
    
    # 检查源文件
    checks_total=$((checks_total + 1))
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then
        log_success "✓ Debian 源文件已配置"
        checks_passed=$((checks_passed + 1))
    else
        log_error "✗ Debian 源文件缺失"
    fi
    
    checks_total=$((checks_total + 1))
    if [ -f /etc/apt/sources.list.d/pve-no-subscription.sources ]; then
        log_success "✓ PVE 源文件已配置"
        checks_passed=$((checks_passed + 1))
    else
        log_error "✗ PVE 源文件缺失"
    fi
    
    # 检查企业源是否禁用
    checks_total=$((checks_total + 1))
    if ! [ -f /etc/apt/sources.list.d/pve-enterprise.sources ]; then
        log_success "✓ 企业源已禁用"
        checks_passed=$((checks_passed + 1))
    else
        log_warn "⚠ 企业源未禁用"
    fi
    
    # 检查 Fake subscription
    checks_total=$((checks_total + 1))
    if [ -f /etc/pve/subscription ] && grep -q '"status": "Active"' /etc/pve/subscription 2>/dev/null; then
        log_success "✓ Fake subscription 已应用"
        checks_passed=$((checks_passed + 1))
    else
        log_error "✗ Fake subscription 未应用"
    fi
    
    # 检查持久化服务
    checks_total=$((checks_total + 1))
    if systemctl is-enabled pve-nosub-patcher.service >/dev/null 2>&1; then
        log_success "✓ 持久化服务已启用"
        checks_passed=$((checks_passed + 1))
    else
        log_warn "⚠ 持久化服务未启用"
    fi
    
    echo ""
    log_info "验证结果: $checks_passed/$checks_total 项检查通过"
    
    if [ $checks_passed -eq $checks_total ]; then
        log_success "✓ 所有检查通过"
        return 0
    else
        log_warn "⚠ 部分检查失败，请查看上述输出"
        return 1
    fi
}

# ============================================================================
# 帮助信息
# ============================================================================
show_help() {
    cat <<EOF
用法: $SCRIPT_NAME [选项]

选项:
    -h, --help              显示此帮助信息
    -v, --version           显示脚本版本
    -d, --dry-run           模拟运行，不进行实际操作
    -r, --rollback PATH     回滚到指定备份目录

示例:
    # 正常执行
    sudo ./$SCRIPT_NAME
    
    # 模拟运行
    sudo ./$SCRIPT_NAME --dry-run
    
    # 回滚配置
    sudo ./$SCRIPT_NAME --rollback /etc/apt/sources.list.d/backups/backup_20260314_120000

EOF
}

# ============================================================================
# 回滚函数
# ============================================================================
rollback_config() {
    local backup_path="$1"
    
    if [ ! -d "$backup_path" ]; then
        log_error "备份目录不存在: $backup_path"
        return 1
    fi
    
    log_step "开始回滚配置..."
    log_warn "这将覆盖当前的 APT 源配置"
    
    if [ $DRY_RUN -eq 0 ]; then
        read -p "确认回滚? (y/N) " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "回滚已取消"
            return 0
        fi
    fi
    
    if cp -r "$backup_path"/* /etc/apt/ 2>/dev/null; then
        log_success "✓ 配置已回滚"
        
        if run_cmd apt update -y; then
            log_success "✓ APT 缓存已更新"
            return 0
        else
            log_error "APT 缓存更新失败"
            return 1
        fi
    else
        log_error "回滚失败"
        return 1
    fi
}

# ============================================================================
# 主函数
# ============================================================================
main() {
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                echo "$SCRIPT_NAME version $SCRIPT_VERSION"
                exit 0
                ;;
            -d|--dry-run)
                DRY_RUN=1
                log_warn "模拟运行模式已启用"
                ;;
            -r|--rollback)
                rollback_config "$2"
                exit $?
                ;;
            *)
                log_error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
        shift
    done
    
    # 初始化
    init_log
    setup_trap
    
    echo ""
    echo "========================================"
    echo "  PVE 智能镜像源配置 + Fake subscription"
    echo "  版本: v$SCRIPT_VERSION"
    echo "========================================"
    echo ""
    
    # 权限和命令检查
    check_root
    check_commands
    verify_pve_env
    check_network
    
    # 获取执行锁
    acquire_lock
    
    # 网络环境检测
    detect_environment
    
    # 系统状态快照
    snapshot_before
    
    # 配置源文件
    backup_sources || { log_error "备份失败"; exit 1; }
    setup_debian_sources || { log_error "Debian 源配置失败"; exit 1; }
    setup_pve_sources || { log_error "PVE 源配置失败"; exit 1; }
    setup_ceph_sources || { log_error "Ceph 源配置失败"; exit 1; }
    disable_enterprise_sources
    
    # 更新 APT 缓存
    update_apt_cache || { log_error "APT 缓存更新失败"; exit 1; }
    
    # 应用 Fake subscription
    patch_subscription_immediate || { log_error "Fake subscription 应用失败"; exit 1; }
    setup_persistent_patch || { log_error "持久化机制配置失败"; exit 1; }
    
    # 系统状态快照和报告
    snapshot_after
    generate_diff_report
    
    # 验证配置
    verify_configuration
    
    echo ""
    log_success "✓ 所有配置已完成"
    log_info "详细日志: $LOG_FILE"
}

# ============================================================================
# 脚本入口
# ============================================================================
if [ "[0;36m${BASH_SOURCE[0]}" = "[0;36m${0}" ]; then
    main "$@"
fi
