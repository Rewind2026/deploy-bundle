#!/usr/bin/env bash
# healthcheck.sh - 部署后体检

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh" 2>/dev/null || true

ENV_FILE="/opt/deploy-bundle.env"
[[ -f "${ENV_FILE}" ]] && source "${ENV_FILE}"

LOG_FILE="/var/log/installer_healthcheck_$(date +%Y%m%d_%H%M%S).log"
REPORT_FILE="/var/log/installer_healthcheck_$(hostname)_$(date +%Y%m%d_%H%M%S).txt"

if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_YEL=$'\033[0;33m'; C_GRN=$'\033[0;32m'; C_BLU=$'\033[0;34m'; C_RST=$'\033[0m'
else
    C_RED=""; C_YEL=""; C_GRN=""; C_BLU=""; C_RST=""
fi

log()  { local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"; printf '[%s] %s\n' "${ts}" "$*" | tee -a "${LOG_FILE}"; }
ok()   { printf '%s[OK]%s %s\n' "${C_GRN}" "${C_RST}" "$*" | tee -a "${LOG_FILE}"; }
warn() { printf '%s[WARN]%s %s\n' "${C_YEL}" "${C_RST}" "$*" | tee -a "${LOG_FILE}"; }
err()  { printf '%s[ERROR]%s %s\n' "${C_RED}" "${C_RST}" "$*" | tee -a "${LOG_FILE}"; }
hdr()  { printf '\n%s===== %s =====%s\n' "${C_BLU}" "$*" "${C_RST}" | tee -a "${LOG_FILE}"; }

FAIL=0
record_fail() { FAIL=$((FAIL+1)); }

# ---- JDK ----
hdr "JDK health"
if [[ -x "${TARGET_JDK_DIR:-/opt/jdk}/bin/java" ]]; then
    "${TARGET_JDK_DIR}/bin/java" -version 2>&1 | head -n1 | tee -a "${LOG_FILE}"
    ok "JDK binary present"
else
    err "JDK not installed at ${TARGET_JDK_DIR:-/opt/jdk}"; record_fail
fi
if command -v java >/dev/null 2>&1; then
    ok "java in PATH"
else
    warn "java not in PATH"; record_fail
fi

# ---- MySQL ----
hdr "MySQL health"
if command -v mysql >/dev/null 2>&1 || [[ -x "${TARGET_MYSQL_DIR:-/opt/mysql}/bin/mysql" ]]; then
    ok "MySQL client present"
else
    err "MySQL client missing"; record_fail
fi
if [[ "${HAVE_SYSTEMD:-0}" -eq 1 ]] && systemctl is-active mysqld >/dev/null 2>&1; then
    ok "mysqld service active"
elif pgrep -x mysqld >/dev/null 2>&1; then
    ok "mysqld process running (no systemd)"
else
    err "mysqld not running"; record_fail
fi
# 端口检查
mysql_port="${MYSQL_PORT:-3306}"
if command -v ss >/dev/null 2>&1; then
    ss -ltn "( sport = :${mysql_port} )" 2>/dev/null | grep -q LISTEN && ok "MySQL port ${mysql_port} listening" || { err "MySQL port ${mysql_port} not listening"; record_fail; }
fi
# 登录尝试
if [[ -f "${TARGET_DATA_DIR:-/var/lib/mysql}/.root_password" ]]; then
    ADMIN_PW="$(grep 'admin@localhost' "${TARGET_DATA_DIR}/.root_password" | awk '{print $NF}')"
    if [[ -n "${ADMIN_PW}" ]]; then
        if "${TARGET_MYSQL_DIR:-/opt/mysql}/bin/mysql" -uadmin -p"${ADMIN_PW}" -h127.0.0.1 -e "SELECT VERSION();" >/dev/null 2>&1; then
            ok "MySQL login OK (admin@127.0.0.1)"
        else
            warn "MySQL login failed; check .root_password"
        fi
    fi
fi

# ---- Tomcat ----
hdr "Tomcat health"
if [[ -x "${TARGET_TOMCAT_DIR:-/opt/tomcat}/bin/catalina.sh" ]]; then
    ok "catalina.sh present"
else
    err "Tomcat not installed at ${TARGET_TOMCAT_DIR:-/opt/tomcat}"; record_fail
fi
if [[ "${HAVE_SYSTEMD:-0}" -eq 1 ]] && systemctl is-active tomcat >/dev/null 2>&1; then
    ok "tomcat service active"
elif pgrep -f catalina >/dev/null 2>&1; then
    ok "catalina process running"
else
    err "tomcat not running"; record_fail
fi
tomcat_port="${TOMCAT_PORT:-8080}"
if command -v ss >/dev/null 2>&1; then
    ss -ltn "( sport = :${tomcat_port} )" 2>/dev/null | grep -q LISTEN && ok "Tomcat port ${tomcat_port} listening" || { err "Tomcat port ${tomcat_port} not listening"; record_fail; }
fi

# ---- Disk ----
hdr "Disk usage"
ROOT_FREE="$(df -P /opt 2>/dev/null | awk 'NR==2 {print $4}')"
VAR_FREE="$(df -P /var 2>/dev/null | awk 'NR==2 {print $4}')"
MIN_FREE="$(printf '%s\n%s\n' "${ROOT_FREE:-0}" "${VAR_FREE:-0}" | sort -n | head -n1)"
if [[ "${MIN_FREE:-0}" -lt 1048576 ]]; then
    warn "Disk free space < 1G (root=/opt:${ROOT_FREE}K var:${VAR_FREE}K)"
else
    ok "Disk space OK (/opt:${ROOT_FREE}K var:${VAR_FREE}K)"
fi

# ---- Auditd ----
hdr "Auditd (optional)"
if [[ "${HAVE_SYSTEMD:-0}" -eq 1 ]] && systemctl is-active auditd >/dev/null 2>&1; then
    TMP_OUT="$(mktemp)"
    ausearch -m USER_LOGIN -ts today > "${TMP_OUT}" 2>/dev/null || true
    LINES="$(wc -l < "${TMP_OUT}" 2>/dev/null || echo 0)"
    ok "Auditd entries today: ${LINES}"
    rm -f "${TMP_OUT}"
fi

# ---- Summary ----
hdr "Summary"
if [[ "${FAIL}" -eq 0 ]]; then
    printf '%sALL CHECKS PASSED%s\n' "${C_GRN}" "${C_RST}" | tee -a "${LOG_FILE}"
    exit 0
else
    printf '%s%d CHECKS FAILED%s\n' "${C_RED}" "${FAIL}" "${C_RST}" | tee -a "${LOG_FILE}"
    exit "${EX_HEALTH:-7}"
fi