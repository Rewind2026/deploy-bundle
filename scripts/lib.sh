#!/usr/bin/env bash
# =============================================================================
# lib.sh — deploy-bundle 子脚本公共库
# -----------------------------------------------------------------------------
# 由 installer.sh 或各 stage 子脚本 source。
# 不直接执行。
# =============================================================================

# 防止重复 source
[[ -n "${_DEPLOY_BUNDLE_LIB_LOADED:-}" ]] && return 0
_DEPLOY_BUNDLE_LIB_LOADED=1

set -Eeuo pipefail

# -----------------------------------------------------------------------------
# 常量（从 /opt/deploy-bundle.env 覆盖）
# -----------------------------------------------------------------------------
: "${DEPLOY_BUNDLE_ROOT:=/opt/deploy-bundle}"
: "${DEPLOY_MODE:=interactive}"
: "${DEPLOY_STAGE:=all}"
: "${DEPLOY_LANG:=zh-CN}"
: "${MYSQL_PORT:=3306}"
: "${TOMCAT_PORT:=8080}"
: "${SKIP_MYSQL:=0}"
: "${SKIP_TOMCAT:=0}"
: "${SKIP_SELINUX:=0}"
: "${SKIP_FIREWALL:=0}"
: "${TARGET_BASE:=/opt}"
: "${TARGET_JDK_DIR:=/opt/jdk}"
: "${TARGET_MYSQL_DIR:=/opt/mysql}"
: "${TARGET_TOMCAT_DIR:=/opt/tomcat}"
: "${TARGET_DATA_DIR:=/var/lib/mysql}"
: "${TARGET_BACKUP_ROOT:=/opt/deploy-bundle-backups}"
: "${LOG_FILE:=/var/log/installer_lib.log}"
: "${REPORT_FILE:=/var/log/installer_report.txt}"
: "${PKG_DIR:=${DEPLOY_BUNDLE_ROOT}/packages}"
: "${CFG_DIR:=${DEPLOY_BUNDLE_ROOT}/configs}"
: "${SCRIPTS_DIR:=${DEPLOY_BUNDLE_ROOT}/scripts}"
: "${DETECT_CACHE:=/tmp/deploy-bundle.detect}"

# 退出码
EX_OK=0
EX_USAGE=1
EX_SYS=2
EX_DEPS=3
EX_SELINUX=4
EX_NET=5
EX_CLEANUP=6
EX_HEALTH=7

# -----------------------------------------------------------------------------
# 日志
# -----------------------------------------------------------------------------
log() {
    local level="$1"; shift
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[${ts}] [${level}] $*"
    printf '%s\n' "${line}" >&2
    if [[ -n "${LOG_FILE}" ]]; then
        printf '%s\n' "${line}" >> "${LOG_FILE}" 2>/dev/null || true
    fi
}
info() { log "INFO"  "$@"; }
warn() { log "WARN"  "$@"; }
err()  { log "ERROR" "$@" >&2; }
ok()   { log "OK"    "$@"; }

die() {
    local code="$1"; shift
    err "$*"
    exit "${code}"
}

# -----------------------------------------------------------------------------
# 干跑模式（只打印，不执行）
# -----------------------------------------------------------------------------
is_dry_run() { [[ "${DEPLOY_MODE}" == "dry-run" ]]; }
DRY_RUN_CMD=()
is_dry_run && DRY_RUN_CMD=(echo "[DRY-RUN]")

run() {
    # 干跑：只打印命令，不执行
    if is_dry_run; then
        echo "[DRY-RUN] $*" >&2
        return 0
    fi
    "$@"
}

# -----------------------------------------------------------------------------
# 探测结果加载
# -----------------------------------------------------------------------------
load_detect_cache() {
    if [[ -f "${DETECT_CACHE}" ]]; then
        # shellcheck disable=SC1090
        source "${DETECT_CACHE}"
        info "已加载探测缓存：${DETECT_CACHE}"
        info "  OS=${OS_ID:-?} ${OS_VERSION:-?} family=${OS_FAMILY:-?} arch=${ARCH:-?} glibc=${GLIBC_VERSION:-?}"
        info "  pkg_mgr=${PKG_MGR:-?} systemd=${HAVE_SYSTEMD:-0} selinux=${HAVE_SELINUX:-0} apparmor=${HAVE_APPARMOR:-0}"
        info "  firewalld=${HAVE_FIREWALLD:-0} ufw=${HAVE_UFW:-0} iptables=${HAVE_IPTABLES:-0}"
    else
        warn "未找到探测缓存：${DETECT_CACHE}，请先运行 precheck.sh"
    fi
}

require_detect() {
    [[ -f "${DETECT_CACHE}" ]] || die "${EX_SYS}" "缺少探测结果，请先运行：bash ${SCRIPTS_DIR}/precheck.sh"
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "${EX_USAGE}" "需要 root 权限，请用 sudo 运行"
}

# -----------------------------------------------------------------------------
# 工具函数
# -----------------------------------------------------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# 备份目录创建
ensure_backup_dir() {
    local sub="${1:-generic}"
    local ts; ts="$(date +%Y%m%d_%H%M%S)"
    local dir="${TARGET_BACKUP_ROOT}/${ts}/${sub}"
    mkdir -p "${dir}"
    printf '%s' "${dir}"
}

# 寻找包目录中匹配 family+arch 的 rpm/deb
find_package() {
    # 用法: find_package <family> <arch> <pattern>
    # 例: find_package rhel8-line x86_64 mysql-community-server
    local family="$1" arch="$2" pattern="$3"
    local subdir="${family}/${arch}"
    if [[ -d "${PKG_DIR}/${subdir}" ]]; then
        find "${PKG_DIR}/${subdir}" -maxdepth 1 -name "${pattern}*" \( -name "*.rpm" -o -name "*.deb" -o -name "*.tar.gz" -o -name "*.tar.xz" \) | head -n 20
    fi
}

# yum/dnf 离线安装 RPM 目录
rpm_install_local() {
    # 用法: rpm_install_local <family> <arch>
    local family="$1" arch="$2"
    local dir="${PKG_DIR}/${family}/${arch}/rpms"
    [[ -d "${dir}" ]] || die "${EX_DEPS}" "未找到 RPM 包目录：${dir}"
    if have_cmd dnf; then
        run dnf -y --disablerepo='*' --enablerepo='local' install "${dir}"/*.rpm
    elif have_cmd yum; then
        run yum -y --disablerepo='*' --enablerepo='local' install "${dir}"/*.rpm
    elif have_cmd rpm; then
        run rpm -Uvh --nodeps --force "${dir}"/*.rpm
    else
        die "${EX_DEPS}" "系统无 dnf/yum/rpm"
    fi
}

# dpkg 离线安装 deb 目录
deb_install_local() {
    local family="$1" arch="$2"
    local dir="${PKG_DIR}/${family}/${arch}/debs"
    [[ -d "${dir}" ]] || die "${EX_DEPS}" "未找到 DEB 包目录：${dir}"
    run dpkg -i "${dir}"/*.deb || run apt-get -y -f install
}

# 提取 tar 包到目标目录
tar_extract() {
    # 用法: tar_extract <tarfile> <target_dir>
    local tarfile="$1" target="$2"
    [[ -f "${tarfile}" ]] || die "${EX_DEPS}" "tar 包不存在：${tarfile}"
    mkdir -p "${target}"
    run tar -xf "${tarfile}" -C "${target}" --strip-components=1
}

# 确认端口未占用（TCP 监听）
port_in_use() {
    local port="$1"
    if have_cmd ss; then
        ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E "[:.]${port}$" >/dev/null
    elif have_cmd netstat; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -E "[:.]${port}$" >/dev/null
    elif have_cmd lsof; then
        lsof -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
    else
        return 1
    fi
}

# -----------------------------------------------------------------------------
# 探测结果字段读取助手
# -----------------------------------------------------------------------------
det_get() {
    # 用法: det_get <key> ; 若 cache 不存在返回空
    [[ -f "${DETECT_CACHE}" ]] || { printf ''; return; }
    local val
    val="$(awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/,""); print; exit}' "${DETECT_CACHE}")"
    # 去除外层引号（cache 是 KEY="VALUE" 格式）
    val="${val#\"}"
    val="${val%\"}"
    # 若值是空 / 全空白，规范化返回空
    if [[ -z "${val}" || ! "${val}" =~ [^[:space:]] ]]; then
        printf ''
    else
        printf '%s' "${val}"
    fi
}

os_family()  { det_get OS_FAMILY; }
arch()       { det_get ARCH; }
os_id()      { det_get OS_ID; }
os_ver()     { det_get OS_VERSION; }
pkg_mgr()    { det_get PKG_MGR; }
have_systemd() { [[ "$(det_get HAVE_SYSTEMD)" == "1" ]]; }
have_selinux() { [[ "$(det_get HAVE_SELINUX)" == "1" ]]; }
have_apparmor() { [[ "$(det_get HAVE_APPARMOR)" == "1" ]]; }
have_firewalld() { [[ "$(det_get HAVE_FIREWALLD)" == "1" ]]; }
have_ufw()      { [[ "$(det_get HAVE_UFW)" == "1" ]]; }
have_iptables() { [[ "$(det_get HAVE_IPTABLES)" == "1" ]]; }

# -----------------------------------------------------------------------------
# 自动检测（供 collect.sh / collect_*.sh 共用）
# -----------------------------------------------------------------------------
auto_detect_family() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        local id="${ID:-unknown}"
        local ver="${VERSION_ID:-${VERSION:-}}"
        case "${id}:${ver}" in
            rhel:7*|centos:7*|rocky:7*|almalinux:7*) echo "rhel7-line" ;;
            rhel:8*|centos:8*|rocky:8*|almalinux:8*) echo "rhel8-line" ;;
            rhel:9*|centos:9*|rocky:9*|almalinux:9*) echo "rhel8-line" ;;   # 9 系沿用 8-line 路径
            openEuler:20.03*)                         echo "rhel7-line" ;;  # glibc 2.28 但 rpmlib 类似 rhel7
            openEuler:22.03*|openEuler:24.03*)        echo "openeuler-line" ;;
            anolis:*|TencentOS:*|openCloudOS:*)        echo "rhel8-line" ;;
            kylin:*V10*|kylin:*v10*)                   echo "rhel7-line" ;;  # V10 SP1/SP2 glibc 2.17
            kylin:*V11*|kylin:*v11*)                   echo "openeuler-line" ;;
            ubuntu:*|debian:*|deepin:*|Kylin:*Desktop*) echo "deb-line" ;;
            # UOS 需要进一步探测
            UOS:*|uos:*)
                if command -v dpkg >/dev/null 2>&1 && dpkg -l >/dev/null 2>&1; then
                    echo "deb-line"
                else
                    echo "rhel8-line"
                fi
                ;;
            *) echo "rhel8-line" ;;  # 保守默认
        esac
    else
        echo "rhel8-line"
    fi
}

auto_detect_arch() {
    uname -m
}

# 根据 family 推导包管理器
detect_pkg_mgr() {
    local fam="${1:-$(auto_detect_family)}"
    case "${fam}" in
        rhel7-line)
            if have_cmd dnf; then echo "dnf"
            elif have_cmd yum; then echo "yum"
            else echo "rpm"
            fi ;;
        rhel8-line|openeuler-line)
            if have_cmd dnf; then echo "dnf"
            elif have_cmd yum; then echo "yum"
            else echo "rpm"
            fi ;;
        deb-line)
            if have_cmd apt-get; then echo "apt-get"
            else echo "dpkg"
            fi ;;
        *) echo "rpm" ;;
    esac
}

# -----------------------------------------------------------------------------
# 公共 stage 入口模板
# -----------------------------------------------------------------------------
stage_begin() {
    info "===== Stage: $* ====="
}

stage_end() {
    info "===== Stage $* done ====="
}