#!/usr/bin/env bash
# rollback.sh - 一键回滚到部署前状态

set -Eeuo pipefail

ENV_FILE="/opt/deploy-bundle.env"
[[ -f "${ENV_FILE}" ]] && source "${ENV_FILE}"

LOG_FILE="${LOG_FILE:-/var/log/installer_rollback_$(date +%Y%m%d_%H%M%S).log}"
BACKUP_ROOT="${TARGET_BACKUP_ROOT:-/opt/deploy-bundle-backups}"
PURGE_DATA=0
AUTO_YES=0

if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_YEL=$'\033[0;33m'; C_GRN=$'\033[0;32m'; C_RST=$'\033[0m'
else
    C_RED=""; C_YEL=""; C_GRN=""; C_RST=""
fi

log()  { local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"; printf '[%s] %s\n' "${ts}" "$*" | tee -a "${LOG_FILE}" >&2; }
info() { log "$*"; }
ok()   { printf '%s[OK]%s %s\n' "${C_GRN}" "${C_RST}" "$*" | tee -a "${LOG_FILE}" >&2; }
warn() { printf '%s[WARN]%s %s\n' "${C_YEL}" "${C_RST}" "$*" | tee -a "${LOG_FILE}" >&2; }
err()  { printf '%s[ERROR]%s %s\n' "${C_RED}" "${C_RST}" "$*" | tee -a "${LOG_FILE}" >&2; }

list_backups() {
    if [[ ! -d "${BACKUP_ROOT}" ]]; then info "无备份目录：${BACKUP_ROOT}"; return 0; fi
    local n=0
    info "可用备份目录：${BACKUP_ROOT}"
    for d in "${BACKUP_ROOT}"/*/; do
        [[ -d "${d}" ]] || continue
        local name; name="$(basename "${d}")"
        local manifest="${d}MANIFEST.txt"
        n=$((n+1))
        printf '  [%d] %s — %s\n' "${n}" "${name}" "$(du -sh "${d}" 2>/dev/null | cut -f1)"
        for sub in "${d}"*/; do
            [[ -d "${sub}" ]] || continue
            printf '       └── %s\n' "$(basename "${sub}")"
        done
        if [[ -f "${manifest}" ]]; then
            head -n 6 "${manifest}" | sed 's/^/       │ /'
        fi
    done
    [[ "${n}" -eq 0 ]] && info "（空）"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge-data)   PURGE_DATA=1 ;;
        --yes|-y)       AUTO_YES=1 ;;
        --list)         list_backups; exit 0 ;;
        --help|-h)      cat <<EOF
Usage: rollback.sh [options]
  (no args)       Roll back to latest backup, keep MySQL data
  --purge-data    Also delete /var/lib/mysql (DANGEROUS)
  --yes           Skip confirmation
  --list          List backups and exit
  --help          Show this help
EOF
            exit 0 ;;
        *) err "Unknown: $1"; exit 1 ;;
    esac
    shift
done

pick_latest_backup() {
    if [[ ! -d "${BACKUP_ROOT}" ]]; then err "No backup directory at ${BACKUP_ROOT}"; exit 1; fi
    local latest=""
    for d in "${BACKUP_ROOT}"/*/; do
        [[ -d "${d}" ]] || continue
        [[ -z "${latest}" || "${d}" > "${latest}" ]] && latest="${d}"
    done
    if [[ -z "${latest}" ]]; then err "No backups found"; exit 1; fi
    echo "${latest%/}"
}

stop_services() {
    info "Stopping services..."
    for svc in mysqld tomcat tomcat9; do
        if systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "${svc}.service"; then
            systemctl stop "${svc}.service" 2>/dev/null || warn "Failed to stop ${svc}.service"
        fi
    done
}

remove_systemd_units() {
    info "Removing systemd units..."
    for svc in mysqld tomcat; do
        local unit="/etc/systemd/system/${svc}.service"
        if [[ -f "${unit}" ]]; then
            systemctl disable "${svc}.service" 2>/dev/null || true
            rm -f "${unit}"
            ok "Removed ${unit}"
        fi
    done
    systemctl daemon-reload 2>/dev/null || true
}

remove_install_dirs() {
    info "Removing /opt installation directories..."
    for d in "${TARGET_JDK_DIR}" "${TARGET_MYSQL_DIR}" "${TARGET_TOMCAT_DIR}"; do
        if [[ -d "${d}" ]]; then rm -rf "${d}"; ok "Removed ${d}"; fi
    done
    for sym in /usr/local/jdk /usr/local/mysql /usr/local/tomcat; do
        if [[ -L "${sym}" ]]; then rm -f "${sym}"; ok "Removed symlink ${sym}"; fi
    done
    if [[ "${PURGE_DATA}" -eq 1 && -d "${TARGET_DATA_DIR}" ]]; then
        warn "PURGE: Removing ${TARGET_DATA_DIR}"
        rm -rf "${TARGET_DATA_DIR}"
    else
        info "Keeping ${TARGET_DATA_DIR} (use --purge-data to remove)"
    fi
}

restore_configs() {
    info "Restoring original config files..."
    local restored=0
    while IFS= read -r bak; do
        [[ -f "${bak}" ]] || continue
        local orig="${bak%.bak}"
        mv -f "${bak}" "${orig}"
        ok "Restored ${orig}"
        restored=$((restored + 1))
    done < <(find /etc /opt -maxdepth 4 -name '*.bak' 2>/dev/null -newer "${BACKUP_ROOT}/../README" 2>/dev/null || true)
    if [[ -f "/opt/deploy-bundle.env" ]]; then
        rm -f "/opt/deploy-bundle.env"
        ok "Removed /opt/deploy-bundle.env"
    fi
    info "Restored ${restored} config files"
}

restore_selinux() {
    if command -v semanage >/dev/null 2>&1; then
        for dom in mysqld_t tomcat_t; do
            if semanage permissive -l 2>/dev/null | grep -qw "${dom}"; then
                semanage permissive -d "${dom}" 2>/dev/null || warn "Failed to remove permissive ${dom}"
                info "Removed permissive domain ${dom}"
            fi
        done
    fi
}

main() {
    info "===== deploy-bundle rollback starting ====="
    [[ "${EUID}" -ne 0 ]] && { err "Rollback must run as root"; exit 1; }
    info "Available backups:"
    list_backups
    local backup; backup="$(pick_latest_backup)"
    info "Selected backup: ${backup}"
    if [[ "${AUTO_YES}" -eq 0 && -t 0 ]]; then
        echo
        printf '%sWARNING%s: This will remove /opt/jdk, /opt/mysql, /opt/tomcat and systemd units.\n' "${C_RED}" "${C_RST}"
        printf 'MySQL data directory (%s) will %s.\n' "${TARGET_DATA_DIR}" "$([[ ${PURGE_DATA} -eq 1 ]] && echo 'BE DELETED' || echo 'be kept')"
        read -rp "Type 'yes' to continue: " ans
        [[ "${ans}" == "yes" ]] || { err "Aborted"; exit 1; }
    fi
    stop_services
    remove_systemd_units
    restore_selinux
    remove_install_dirs
    restore_configs
    if [[ -f "${backup}/MANIFEST.txt" ]]; then
        {
            echo
            echo "[ROLLBACK APPLIED at $(date)]"
        } >> "${backup}/MANIFEST.txt"
    fi
    info "===== Rollback completed ====="
    ok "System restored to pre-deploy state (from backup ${backup})"
    cat <<EOF

${C_GRN}回滚完成（Rollback complete）${C_RST}

如需完全清理 MySQL 数据目录，下次回滚时加 --purge-data 参数。
注意：备份目录本身 ${backup} 保留不动。
EOF
}

main