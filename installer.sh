#!/usr/bin/env bash
# installer.sh - deploy-bundle 主入口
# 跨国产化 Linux 一键部署 MySQL 8 + Tomcat 9 + JDK 8
# 自包含、完全离线、sudo 友好、幂等可回滚
# 用法：
#   sudo bash installer.sh                          # 交互
#   sudo bash installer.sh --auto                   # 全无人工交互
#   sudo bash installer.sh --dry-run                # 打印计划
#   sudo bash installer.sh --rollback               # 回滚
#   sudo bash installer.sh --only=detect            # 仅探测
#   sudo bash installer.sh --only=healthcheck       # 仅跑健康检查
#   sudo bash installer.sh --mysql-port=3307
#   sudo bash installer.sh --tomcat-port=8081
#   sudo bash installer.sh --skip-mysql
#   sudo bash installer.sh --skip-tomcat
#   sudo bash installer.sh --skip-selinux
#   sudo bash installer.sh --lang=en-US
# 退出码：
#   0=成功 1=用户错误 2=系统错误 3=依赖缺失 4=SELinux错误 5=网络 6=卸载 7=健康检查

set -Eeuo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BUNDLE_ROOT="${SCRIPT_DIR}"
readonly VERSION_FILE="${BUNDLE_ROOT}/VERSION"
readonly PKG_DIR="${BUNDLE_ROOT}/packages"
readonly CFG_DIR="${BUNDLE_ROOT}/configs"
readonly SCRIPTS_DIR="${BUNDLE_ROOT}/scripts"

readonly TARGET_BASE="/opt"
readonly TARGET_JDK_DIR="${TARGET_BASE}/jdk"
readonly TARGET_MYSQL_DIR="${TARGET_BASE}/mysql"
readonly TARGET_TOMCAT_DIR="${TARGET_BASE}/tomcat"
readonly TARGET_DATA_DIR="/var/lib/mysql"
readonly TARGET_BACKUP_ROOT="/opt/deploy-bundle-backups"

readonly LOG_DIR="/var/log"
readonly LOG_FILE="${LOG_DIR}/installer_$(date +%Y%m%d_%H%M%S).log"
readonly REPORT_FILE="${LOG_DIR}/installer_report_$(hostname)_$(date +%Y%m%d_%H%M%S).txt"
readonly ENV_FILE="${TARGET_BASE}/deploy-bundle.env"

readonly EX_OK=0
readonly EX_USAGE=1
readonly EX_SYS=2
readonly EX_DEPS=3
readonly EX_SELINUX=4
readonly EX_NET=5
readonly EX_CLEANUP=6
readonly EX_HEALTH=7

MODE="interactive"
RUN_STAGE="all"
LANG_OPT="zh-CN"
MYSQL_PORT=3306
TOMCAT_PORT=8080
SKIP_MYSQL=0
SKIP_TOMCAT=0
SKIP_SELINUX=0
SKIP_FIREWALL=0

declare -g OS_ID=""
declare -g OS_VERSION=""
declare -g OS_FAMILY=""
declare -g ARCH=""
declare -g GLIBC_VERSION=""
declare -g PKG_MGR=""
declare -g HAVE_SYSTEMD=0
declare -g HAVE_SELINUX=0
declare -g HAVE_APPARMOR=0
declare -g HAVE_FIREWALLD=0
declare -g HAVE_UFW=0
declare -g HAVE_IPTABLES=0
declare -g CPU_FLAGS=""
declare -g JAVA_HOME=""
declare -g MYSQL_HOME=""
declare -g CATALINA_HOME=""

log_init() {
    mkdir -p "${LOG_DIR}" 2>/dev/null || true
    : > "${LOG_FILE}"
}

log() {
    local level="$1"; shift
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[${ts}] [${level}] $*"
    printf '%s\n' "${line}"
    printf '%s\n' "${line}" >> "${LOG_FILE}" 2>/dev/null || true
}

info()  { log "INFO"  "$@"; }
warn()  { log "WARN"  "$@"; }
err()   { log "ERROR" "$@" >&2; }
ok()    { log "OK"    "$@"; }

die() {
    local code="$1"; shift
    err "$*"
    exit "${code}"
}

t() {
    local key="$1"
    case "${LANG_OPT}:${key}" in
        zh-CN:help)
            cat <<'EOF'
用法: installer.sh [选项]

模式:
  --auto                 全无人工交互
  --dry-run              打印所有变更计划但不执行
  --rollback             回滚到上次部署前的状态
  --only=STAGE           仅执行某阶段: detect|cleanup|install|healthcheck

配置:
  --mysql-port=PORT      MySQL 端口（默认 3306）
  --tomcat-port=PORT     Tomcat 端口（默认 8080）
  --skip-mysql           跳过 MySQL 安装
  --skip-tomcat          跳过 Tomcat 安装
  --skip-selinux         不调整 SELinux 策略
  --skip-firewall        不动防火墙
  --lang=zh-CN|en-US     日志语言

其他:
  --help, -h             显示帮助
  --version              显示版本
EOF
            ;;
        en-US:help)
            cat <<'EOF'
Usage: installer.sh [options]

Modes:
  --auto                 Fully automatic, no prompts
  --dry-run              Print plan, do not modify
  --rollback             Roll back to pre-deploy state
  --only=STAGE           Run one stage: detect|cleanup|install|healthcheck

Config:
  --mysql-port=PORT
  --tomcat-port=PORT
  --skip-mysql
  --skip-tomcat
  --skip-selinux
  --skip-firewall
  --lang=zh-CN|en-US

Other:
  --help, -h
  --version
EOF
            ;;
        *) printf '%s' "${key}" ;;
    esac
}

usage() {
    t help
    echo
    echo "Exit codes:"
    echo "  0 success | 1 user | 2 system | 3 deps | 4 selinux | 5 net | 6 cleanup | 7 health"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto)        MODE="auto" ;;
            --dry-run)     MODE="dry-run" ;;
            --rollback)    MODE="rollback" ;;
            --only=*)      RUN_STAGE="${1#*=}" ;;
            --mysql-port=*) MYSQL_PORT="${1#*=}" ;;
            --tomcat-port=*) TOMCAT_PORT="${1#*=}" ;;
            --skip-mysql)  SKIP_MYSQL=1 ;;
            --skip-tomcat) SKIP_TOMCAT=1 ;;
            --skip-selinux) SKIP_SELINUX=1 ;;
            --skip-firewall) SKIP_FIREWALL=1 ;;
            --lang=*)      LANG_OPT="${1#*=}" ;;
            -h|--help)     usage; exit "${EX_OK}" ;;
            --version)      show_version; exit "${EX_OK}" ;;
            *) err "Unknown argument: $1"; usage; exit "${EX_USAGE}" ;;
        esac
        shift
    done
    [[ "${MYSQL_PORT}" =~ ^[0-9]+$ ]]  || die "${EX_USAGE}" "Invalid --mysql-port"
    [[ "${TOMCAT_PORT}" =~ ^[0-9]+$ ]] || die "${EX_USAGE}" "Invalid --tomcat-port"
    [[ "${MYSQL_PORT}" -ge 1 && "${MYSQL_PORT}" -le 65535 ]]  || die "${EX_USAGE}" "mysql-port out of range"
    [[ "${TOMCAT_PORT}" -ge 1 && "${TOMCAT_PORT}" -le 65535 ]] || die "${EX_USAGE}" "tomcat-port out of range"
    case "${RUN_STAGE}" in
        all|detect|cleanup|install|healthcheck) ;;
        *) die "${EX_USAGE}" "Invalid --only value: ${RUN_STAGE}" ;;
    esac
}

show_version() {
    if [[ -f "${VERSION_FILE}" ]]; then cat "${VERSION_FILE}"
    else echo "deploy-bundle installer (version unknown)"; fi
}

preflight() {
    info "===== Preflight checks ====="
    if [[ "${EUID}" -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            info "Re-executing via sudo..."
            exec sudo --preserve-env=BASH_ENV -E bash "$0" "$@"
        fi
        die "${EX_USAGE}" "This script must run as root or via sudo"
    fi
    local missing=()
    for cmd in bash tar awk sed grep cut uname; do
        command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "${EX_DEPS}" "Missing critical commands: ${missing[*]}"
    fi
    [[ -d "${PKG_DIR}" ]]     || die "${EX_DEPS}" "Missing packages/ directory"
    [[ -d "${SCRIPTS_DIR}" ]] || die "${EX_DEPS}" "Missing scripts/ directory"
    [[ -d "${CFG_DIR}" ]]     || die "${EX_DEPS}" "Missing configs/ directory"
    info "Bundle root: ${BUNDLE_ROOT}"
    ok "Preflight passed"
}

load_detect_cache() {
    local cache="/tmp/deploy-bundle.detect"
    if [[ -f "${cache}" ]]; then
        # shellcheck disable=SC1090
        source "${cache}"
        info "Loaded cached detect result from ${cache}"
    fi
}

main() {
    log_init
    parse_args "$@"
    preflight "$@"

    info "deploy-bundle installer starting"
    info "Mode: ${MODE}  Stage: ${RUN_STAGE}  Lang: ${LANG_OPT}"
    info "MySQL port: ${MYSQL_PORT}  Tomcat port: ${TOMCAT_PORT}"
    info "Skip flags: mysql=${SKIP_MYSQL} tomcat=${SKIP_TOMCAT} selinux=${SKIP_SELINUX} firewall=${SKIP_FIREWALL}"

    cat > "${ENV_FILE}" <<EOF
# Generated by installer.sh on $(date)
DEPLOY_BUNDLE_ROOT=${BUNDLE_ROOT}
DEPLOY_MODE=${MODE}
DEPLOY_STAGE=${RUN_STAGE}
DEPLOY_LANG=${LANG_OPT}
MYSQL_PORT=${MYSQL_PORT}
TOMCAT_PORT=${TOMCAT_PORT}
SKIP_MYSQL=${SKIP_MYSQL}
SKIP_TOMCAT=${SKIP_TOMCAT}
SKIP_SELINUX=${SKIP_SELINUX}
SKIP_FIREWALL=${SKIP_FIREWALL}
TARGET_BASE=${TARGET_BASE}
TARGET_JDK_DIR=${TARGET_JDK_DIR}
TARGET_MYSQL_DIR=${TARGET_MYSQL_DIR}
TARGET_TOMCAT_DIR=${TARGET_TOMCAT_DIR}
TARGET_DATA_DIR=${TARGET_DATA_DIR}
TARGET_BACKUP_ROOT=${TARGET_BACKUP_ROOT}
LOG_FILE=${LOG_FILE}
REPORT_FILE=${REPORT_FILE}
EOF
    chmod 600 "${ENV_FILE}"

    case "${MODE}" in
        rollback)
            info "Running rollback..."
            bash "${SCRIPTS_DIR}/rollback.sh" || die "${EX_CLEANUP}" "Rollback failed"
            ok "Rollback completed"
            exit "${EX_OK}" ;;
        dry-run)
            info "Running precheck in dry-run mode..."
            bash "${SCRIPTS_DIR}/precheck.sh" --dry-run || die "${EX_SYS}" "Precheck failed"
            ok "Dry-run precheck completed"
            exit "${EX_OK}" ;;
    esac

    case "${RUN_STAGE}" in
        all|detect)
            info "===== Stage: detect ====="
            bash "${SCRIPTS_DIR}/precheck.sh" || die "${EX_SYS}" "Precheck failed" ;;
    esac
    case "${RUN_STAGE}" in
        all|cleanup)
            info "===== Stage: cleanup ====="
            bash "${SCRIPTS_DIR}/cleanup_old.sh" || die "${EX_CLEANUP}" "Cleanup failed" ;;
    esac
    case "${RUN_STAGE}" in
        all|install)
            info "===== Stage: install ====="
            bash "${SCRIPTS_DIR}/install_jdk.sh" || die "${EX_SYS}" "JDK install failed"
            [[ "${SKIP_MYSQL}" -eq 0 ]] && bash "${SCRIPTS_DIR}/install_mysql.sh" || warn "Skipping MySQL"
            [[ "${SKIP_TOMCAT}" -eq 0 ]] && bash "${SCRIPTS_DIR}/install_tomcat.sh" || warn "Skipping Tomcat"
            [[ "${SKIP_SELINUX}" -eq 0 ]] && bash "${SCRIPTS_DIR}/selinux_relax.sh" || warn "Skipping SELinux"
            [[ "${SKIP_FIREWALL}" -eq 0 ]] && bash "${SCRIPTS_DIR}/firewall.sh" || warn "Skipping firewall"
            bash "${SCRIPTS_DIR}/systemd_register.sh" || die "${EX_SYS}" "systemd registration failed" ;;
    esac
    case "${RUN_STAGE}" in
        all|healthcheck)
            info "===== Stage: healthcheck ====="
            if ! bash "${SCRIPTS_DIR}/healthcheck.sh"; then
                warn "Health check reported issues (exit code $?)"
                warn "Run \`bash ${SCRIPTS_DIR}/healthcheck.sh\` again anytime"
            fi ;;
    esac

    info "===== Deployment completed ====="
    info "Log:    ${LOG_FILE}"
    info "Report: ${REPORT_FILE}"
    cat <<EOF

==========================================================================
部署完成（Deployment complete）

日志：   ${LOG_FILE}
报告：   ${REPORT_FILE}
环境变量：${ENV_FILE}

下一步建议：
  1. 查看健康检查报告：    less ${REPORT_FILE}
  2. 测试 Tomcat：         curl -I http://localhost:${TOMCAT_PORT}/
  3. 测试 MySQL：          mysql -u root -p
  4. 如需回滚：            sudo bash ${BUNDLE_ROOT}/installer.sh --rollback
==========================================================================
EOF
    exit "${EX_OK}"
}

main "$@"