#!/usr/bin/env bash
# precheck.sh - 环境探测与旧版本扫描
# 见 docs/COMPATIBILITY.md 与 detect_kylin_uos.sh 配套使用

set -Eeuo pipefail

ENV_FILE="/opt/deploy-bundle.env"
[[ -f "${ENV_FILE}" ]] && source "${ENV_FILE}"

LOG_FILE="${LOG_FILE:-/var/log/installer_$(date +%Y%m%d_%H%M%S).log}"
DETECT_CACHE="/tmp/deploy-bundle.detect"
DETECT_REPORT="/var/log/installer_detect_$(hostname)_$(date +%Y%m%d_%H%M%S).txt"
DRY_RUN=0

if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_YEL=$'\033[0;33m'; C_GRN=$'\033[0;32m'
    C_BLU=$'\033[0;34m'; C_RST=$'\033[0m'
else
    C_RED=""; C_YEL=""; C_GRN=""; C_BLU=""; C_RST=""
fi

log()  { local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"; printf '[%s] %s\n' "${ts}" "$*" | tee -a "${LOG_FILE}"; }
info() { log "$*"; }
ok()   { printf '%s[OK]%s %s\n' "${C_GRN}" "${C_RST}" "$*" | tee -a "${LOG_FILE}"; }
warn() { printf '%s[WARN]%s %s\n' "${C_YEL}" "${C_RST}" "$*" | tee -a "${LOG_FILE}"; }
err()  { printf '%s[ERROR]%s %s\n' "${C_RED}" "${C_RST}" "$*" | tee -a "${LOG_FILE}"; }
hdr()  { printf '\n%s===== %s =====%s\n' "${C_BLU}" "$*" "${C_RST}" | tee -a "${LOG_FILE}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        *) err "Unknown arg: $1"; exit 1 ;;
    esac
    shift
done

detect_os() {
    hdr "OS / Architecture / Package Manager"
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-${VERSION:-unknown}}"
        OS_NAME="${NAME:-${ID:-unknown}}"
    else
        OS_ID="unknown"; OS_VERSION="unknown"; OS_NAME="unknown"
    fi
    info "OS: ${OS_NAME} (ID=${OS_ID} VERSION=${OS_VERSION})"
    ARCH="$(uname -m)"
    info "Architecture: ${ARCH}"
    CPU_FLAGS=""
    if [[ -f /proc/cpuinfo ]]; then
        local cpu_line
        cpu_line="$(grep -m1 '^flags[[:space:]]*: ' /proc/cpuinfo || true)"
        if [[ -z "${cpu_line}" ]]; then
            cpu_line="$(grep -m1 '^Features[[:space:]]*: ' /proc/cpuinfo || true)"
        fi
        CPU_FLAGS="$(printf '%s\n' "${cpu_line}" | sed -E 's/^[^:]+:[[:space:]]*//' || true)"
    fi
    if [[ -z "${CPU_FLAGS}" ]]; then
        warn "未从 /proc/cpuinfo 提取 CPU flags"
    else
        info "CPU flags: $(printf '%s' "${CPU_FLAGS}" | tr ' ' '\n' | head -n 8 | tr '\n' ' ')..."
    fi
    if command -v rpm >/dev/null 2>&1; then
        PKG_MGR="rpm"
    elif command -v dpkg >/dev/null 2>&1; then
        PKG_MGR="dpkg"
    else
        err "No rpm or dpkg found; unsupported system"; exit 2
    fi
    info "Package manager: ${PKG_MGR}"

    OS_FAMILY="unknown"
    # 优先调用 Kylin/UOS 专项探测
    source "${SCRIPTS_DIR:-/opt/deploy-bundle/scripts}/detect_kylin_uos.sh" 2>/dev/null || true
    if [[ -n "${KYLIN_UOS_FAMILY:-}" ]]; then
        OS_FAMILY="${KYLIN_UOS_FAMILY}"
        info "Kylin/UOS 专项探测：${KYLIN_UOS_OS:-unknown} (family=${OS_FAMILY}, glibc=${KYLIN_UOS_GLIBC:-?})"
    else
        case "${OS_ID}" in
            kylin)
                case "${OS_VERSION}" in
                    V10*)      OS_FAMILY="rhel8-line" ;;
                    V11*)      OS_FAMILY="openeuler-line" ;;
                    *)         OS_FAMILY="rhel8-line" ;;
                esac ;;
            uniontech|uos)
                case "${OS_VERSION}" in
                    20*|1050*|1060*|1070*)
                        if command -v dpkg >/dev/null 2>&1 && dpkg -l >/dev/null 2>&1; then
                            OS_FAMILY="deb-line"
                        else
                            OS_FAMILY="openeuler-line"
                        fi ;;
                    *) OS_FAMILY="deb-line" ;;
                esac ;;
            openEuler)
                case "${OS_VERSION}" in
                    20.*) OS_FAMILY="rhel7-line" ;;
                    *)    OS_FAMILY="openeuler-line" ;;
                esac ;;
            anolis)
                case "${OS_VERSION}" in
                    7*) OS_FAMILY="rhel7-line" ;;
                    *)  OS_FAMILY="openeuler-line" ;;
                esac ;;
            centos|rhel|rocky|almalinux|ol)
                case "${OS_VERSION%%.*}" in
                    7) OS_FAMILY="rhel7-line" ;;
                    8) OS_FAMILY="rhel8-line" ;;
                    9|10) OS_FAMILY="openeuler-line" ;;
                    *)  OS_FAMILY="rhel8-line" ;;
                esac ;;
            debian|ubuntu|deepin) OS_FAMILY="deb-line" ;;
            loongnix)             OS_FAMILY="loongarch" ;;
            *)
                warn "Unknown OS ID=${OS_ID}, guessing"
                if [[ "${PKG_MGR}" == "rpm" ]]; then OS_FAMILY="rhel8-line"
                else OS_FAMILY="deb-line"; fi ;;
        esac
    fi
    info "OS family: ${OS_FAMILY}"
    if [[ "${ARCH}" == "loongarch64" ]]; then
        OS_FAMILY="loongarch"
        warn "LoongArch detected. Will use Loongson ecosystem packages."
    fi
}

detect_glibc() {
    hdr "glibc version"
    if command -v ldd >/dev/null 2>&1; then
        local line
        line="$(ldd --version 2>&1 | head -n1)"
        GLIBC_VERSION="$(echo "${line}" | grep -oE '[0-9]+\.[0-9]+' | head -n1)"
    fi
    if [[ -z "${GLIBC_VERSION}" && -f /lib64/libc.so.6 ]]; then
        GLIBC_VERSION="$(/lib64/libc.so.6 2>&1 | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)"
    fi
    if [[ -z "${GLIBC_VERSION}" ]]; then
        GLIBC_VERSION="2.17"
        warn "Could not detect glibc, assuming 2.17"
    fi
    info "glibc: ${GLIBC_VERSION}"
    awk -v g="${GLIBC_VERSION}" 'BEGIN {
        if (g+0 >= 2.31) print "  Recommended: linux-glibc2.28";
        else if (g+0 >= 2.28) print "  Recommended: linux-glibc2.28";
        else if (g+0 >= 2.17) print "  Recommended: linux-glibc2.17 (legacy)";
        else print "  ERROR: glibc < 2.17";
    }'
}

detect_capabilities() {
    hdr "System capabilities"
    HAVE_SYSTEMD=0; HAVE_SELINUX=0; HAVE_APPARMOR=0
    HAVE_FIREWALLD=0; HAVE_UFW=0; HAVE_IPTABLES=0
    if [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
        HAVE_SYSTEMD=1; ok "systemd: available"
    else
        warn "systemd: not detected"
    fi
    if command -v getenforce >/dev/null 2>&1; then
        local mode; mode="$(getenforce 2>/dev/null || echo unknown)"
        if [[ "${mode}" != "unknown" ]]; then
            HAVE_SELINUX=1; info "SELinux: ${mode}"
        fi
    fi
    [[ "${HAVE_SELINUX}" -eq 0 ]] && info "SELinux: not present"
    if command -v aa-status >/dev/null 2>&1; then
        HAVE_APPARMOR=1; info "AppArmor: available"
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
        HAVE_FIREWALLD=1; ok "firewalld: active"
    fi
    if command -v ufw >/dev/null 2>&1; then HAVE_UFW=1; info "ufw: available"; fi
    if command -v iptables >/dev/null 2>&1; then HAVE_IPTABLES=1; fi
    if [[ "${ARCH}" == "x86_64" ]]; then
        if ! grep -qw avx2 <<<"${CPU_FLAGS}"; then warn "CPU lacks AVX2"; fi
        if ! grep -qw aes <<<"${CPU_FLAGS}"; then warn "CPU lacks AES-NI"; fi
    fi
    if [[ "${ARCH}" == "aarch64" ]]; then
        if ! grep -qw asimd <<<"${CPU_FLAGS}"; then warn "ARM CPU lacks ASIMD/NEON"; fi
    fi
}

detect_existing_jdk() {
    hdr "Existing JDK detection"
    local found=()
    if command -v java >/dev/null 2>&1; then
        local v; v="$(java -version 2>&1 | head -n1)"
        info "java in PATH: ${v}"
        local real; real="$(readlink -f "$(command -v java)" 2>/dev/null || echo unknown)"
        info "java real path: ${real}"
        found+=("path:$(command -v java):${real}")
    fi
    if [[ "${PKG_MGR}" == "rpm" ]]; then
        while IFS= read -r pkg; do found+=("rpm:${pkg}"); done < <(rpm -qa 2>/dev/null | grep -Ei '^(jdk|jre|java|openjdk|ibmjava)' || true)
    else
        while IFS= read -r pkg; do found+=("dpkg:${pkg}"); done < <(dpkg -l 2>/dev/null | grep -Ei '^ii[[:space:]]+(jdk|jre|java|openjdk)' | awk '{print $2}' || true)
    fi
    local jvm_paths=()
    for d in /opt/jdk* /usr/local/jdk* /usr/lib/jvm/*; do
        [[ -d "${d}" && -x "${d}/bin/java" ]] && jvm_paths+=("${d}")
    done
    if [[ ${#found[@]} -eq 0 && ${#jvm_paths[@]} -eq 0 ]]; then
        ok "No JDK installed"
    else
        warn "Found ${#found[@]} JDK-related packages and ${#jvm_paths[@]} JDK directories"
        [[ ${#found[@]} -gt 0 ]] && printf '  Pkgs:  %s\n' "${found[*]}" | tee -a "${LOG_FILE}"
        [[ ${#jvm_paths[@]} -gt 0 ]] && printf '  Paths: %s\n' "${jvm_paths[*]}" | tee -a "${LOG_FILE}"
    fi
    EXISTING_JDK_LIST="${found[*]:-}"
    DETECTED_JVMS="${jvm_paths[*]:-}"
    DETECTED_JVMS="${DETECTED_JVMS// /;}"
}

detect_existing_mysql() {
    hdr "Existing MySQL/MariaDB detection"
    local found=()
    if [[ "${PKG_MGR}" == "rpm" ]]; then
        while IFS= read -r pkg; do found+=("${pkg}"); done < <(rpm -qa 2>/dev/null | grep -Ei '^(mysql|mariadb|percona)' || true)
    else
        while IFS= read -r pkg; do found+=("${pkg}"); done < <(dpkg -l 2>/dev/null | grep -Ei '^ii[[:space:]]+(mysql|mariadb|percona)' | awk '{print $2}' || true)
    fi
    local bins=()
    for b in /usr/local/mysql/bin/mysqld /opt/mysql/bin/mysqld /usr/sbin/mysqld; do
        [[ -x "${b}" ]] && bins+=("${b}")
    done
    local units=()
    for u in mysqld mariadb mysql; do
        if [[ "${HAVE_SYSTEMD}" -eq 1 ]] && systemctl list-unit-files "${u}.service" 2>/dev/null | grep -q "${u}.service"; then
            units+=("${u}.service")
        fi
    done
    if [[ ${#found[@]} -eq 0 && ${#bins[@]} -eq 0 && ${#units[@]} -eq 0 ]]; then
        ok "No MySQL/MariaDB installed"
    else
        warn "Found existing MySQL artifacts:"
        [[ ${#found[@]} -gt 0 ]] && printf '  RPM/Deb: %s\n' "${found[*]}" | tee -a "${LOG_FILE}"
        [[ ${#bins[@]} -gt 0  ]] && printf '  Bin:     %s\n' "${bins[*]}"   | tee -a "${LOG_FILE}"
        [[ ${#units[@]} -gt 0 ]] && printf '  Units:   %s\n' "${units[*]}"  | tee -a "${LOG_FILE}"
    fi
    EXISTING_MYSQL_LIST="${found[*]:-}"
    EXISTING_MYSQL_UNITS="${units[*]:-}"
    if [[ ${#bins[@]} -gt 0 ]]; then
        local first_bin="${bins[0]}"
        EXISTING_MYSQL_HOME="$(dirname "$(dirname "${first_bin}")")"
    else
        EXISTING_MYSQL_HOME=""
    fi
}

detect_existing_tomcat() {
    hdr "Existing Tomcat detection"
    local found=()
    for d in /usr/local/tomcat /opt/tomcat /opt/apache-tomcat* /srv/tomcat; do
        [[ -d "${d}" ]] && found+=("dir:${d}")
    done
    local units=()
    for u in tomcat tomcat9; do
        if [[ "${HAVE_SYSTEMD}" -eq 1 ]] && systemctl list-unit-files "${u}.service" 2>/dev/null | grep -q "${u}.service"; then
            units+=("${u}.service")
        fi
    done
    if [[ ${#found[@]} -eq 0 && ${#units[@]} -eq 0 ]]; then
        ok "No Tomcat installed"
    else
        warn "Found existing Tomcat:"
        [[ ${#found[@]} -gt 0 ]] && printf '  Dirs:   %s\n' "${found[*]}" | tee -a "${LOG_FILE}"
        [[ ${#units[@]} -gt 0 ]] && printf '  Units:  %s\n' "${units[*]}" | tee -a "${LOG_FILE}"
    fi
    EXISTING_TOMCAT_LIST="${found[*]:-}"
    EXISTING_TOMCAT_UNITS="${units[*]:-}"
    if [[ ${#found[@]} -gt 0 ]]; then
        local first="${found[0]}"
        EXISTING_TOMCAT_HOME="${first#dir:}"
    else
        EXISTING_TOMCAT_HOME=""
    fi
}

scan_java_home_refs() {
    hdr "JAVA_HOME references scan"
    local refs
    refs="$(grep -RIl --include='*.sh' --include='*.service' \
        --exclude-dir='deploy-bundle' \
        -E 'JAVA_HOME' /opt /usr/local /etc/systemd/system 2>/dev/null | head -n 50 || true)"
    if [[ -z "${refs}" ]]; then
        ok "No JAVA_HOME references found"
    else
        warn "JAVA_HOME referenced by:"
        printf '%s\n' "${refs}" | tee -a "${LOG_FILE}"
    fi
    JAVA_HOME_REFS="${refs}"
}

check_port() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltn "( sport = :${port} )" 2>/dev/null | grep -q LISTEN
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | grep -qE ":${port}[[:space:]]"
    fi
}

detect_port_conflict() {
    hdr "Port conflict check"
    if check_port "${MYSQL_PORT:-3306}"; then warn "Port ${MYSQL_PORT:-3306} already in use"
    else ok "Port ${MYSQL_PORT:-3306} is free"; fi
    if check_port "${TOMCAT_PORT:-8080}"; then warn "Port ${TOMCAT_PORT:-8080} already in use"
    else ok "Port ${TOMCAT_PORT:-8080} is free"; fi
}

write_cache() {
    cat > "${DETECT_CACHE}" <<EOF
# Generated by precheck.sh on $(date)
OS_ID="${OS_ID}"
OS_VERSION="${OS_VERSION}"
OS_NAME="${OS_NAME}"
OS_FAMILY="${OS_FAMILY}"
ARCH="${ARCH}"
GLIBC_VERSION="${GLIBC_VERSION}"
PKG_MGR="${PKG_MGR}"
HAVE_SYSTEMD=${HAVE_SYSTEMD}
HAVE_SELINUX=${HAVE_SELINUX}
HAVE_APPARMOR=${HAVE_APPARMOR}
HAVE_FIREWALLD=${HAVE_FIREWALLD}
HAVE_UFW=${HAVE_UFW}
HAVE_IPTABLES=${HAVE_IPTABLES}
CPU_FLAGS="${CPU_FLAGS}"
EXISTING_JDK_LIST="${EXISTING_JDK_LIST:-}"
EXISTING_MYSQL_LIST="${EXISTING_MYSQL_LIST:-}"
EXISTING_MYSQL_UNITS="${EXISTING_MYSQL_UNITS:-}"
EXISTING_TOMCAT_LIST="${EXISTING_TOMCAT_LIST:-}"
EXISTING_TOMCAT_UNITS="${EXISTING_TOMCAT_UNITS:-}"
JAVA_HOME_REFS="${JAVA_HOME_REFS:-}"
DETECTED_JVMS="${DETECTED_JVMS:-}"
EXISTING_MYSQL_HOME="${EXISTING_MYSQL_HOME:-}"
EXISTING_TOMCAT_HOME="${EXISTING_TOMCAT_HOME:-}"
EOF
    chmod 600 "${DETECT_CACHE}"
    info "Detect cache written to ${DETECT_CACHE}"
}

write_report() {
    {
        echo "============================================="
        echo " deploy-bundle Precheck Report"
        echo " Host:     $(hostname)"
        echo " Date:     $(date)"
        echo "============================================="
        echo
        echo "[OS] ${OS_NAME} (${OS_ID} ${OS_VERSION})"
        echo "[Family] ${OS_FAMILY}"
        echo "[Architecture] ${ARCH}"
        echo "[glibc] ${GLIBC_VERSION}"
        echo "[Package Manager] ${PKG_MGR}"
        echo
        echo "[Capabilities]"
        echo "  systemd  = ${HAVE_SYSTEMD}"
        echo "  SELinux  = ${HAVE_SELINUX}"
        echo "  AppArmor = ${HAVE_APPARMOR}"
        echo "  firewalld= ${HAVE_FIREWALLD}"
        echo "  ufw      = ${HAVE_UFW}"
        echo "  iptables = ${HAVE_IPTABLES}"
        echo
        echo "[Existing Installations]"
        echo "  JDK:     ${EXISTING_JDK_LIST:-none}"
        echo "  MySQL:   ${EXISTING_MYSQL_LIST:-none}"
        echo "  MySQL Units: ${EXISTING_MYSQL_UNITS:-none}"
        echo "  Tomcat:  ${EXISTING_TOMCAT_LIST:-none}"
        echo "  Tomcat Units: ${EXISTING_TOMCAT_UNITS:-none}"
        echo
        echo "[JAVA_HOME References]"
        if [[ -n "${JAVA_HOME_REFS:-}" ]]; then echo "${JAVA_HOME_REFS}"
        else echo "  none"; fi
        echo
        echo "[Bundle root] ${BUNDLE_ROOT:-/opt/deploy-bundle}"
        echo "============================================="
    } > "${DETECT_REPORT}"
    info "Detect report written to ${DETECT_REPORT}"
}

main() {
    hdr "deploy-bundle precheck starting"
    info "Log file: ${LOG_FILE}"
    if [[ "${DRY_RUN}" -eq 1 ]]; then warn "DRY-RUN MODE: no changes will be made"; fi
    detect_os
    detect_glibc
    detect_capabilities
    detect_existing_jdk
    detect_existing_mysql
    detect_existing_tomcat
    scan_java_home_refs
    detect_port_conflict
    write_cache
    write_report
    hdr "Precheck finished"
    info "View report: cat ${DETECT_REPORT}"
    cat <<EOF

${C_BLU}推荐安装策略${C_RST}：
  - OS 族：${OS_FAMILY}
  - 架构：${ARCH}
  - glibc：${GLIBC_VERSION}
  - JDK 路径：${TARGET_JDK_DIR:-/opt/jdk}
  - MySQL 路径：${TARGET_MYSQL_DIR:-/opt/mysql}
  - Tomcat 路径：${TARGET_TOMCAT_DIR:-/opt/tomcat}
  - 数据目录：${TARGET_DATA_DIR:-/var/lib/mysql}

${C_YEL}下一步${C_RST}：
  1. 如有旧版本警告，请人工确认 cleanup_old.sh 的卸载范围
  2. 执行 sudo bash ${BUNDLE_ROOT:-/opt/deploy-bundle}/installer.sh --auto 开始部署
EOF
}

main