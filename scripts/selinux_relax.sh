#!/usr/bin/env bash
# selinux_relax.sh - SELinux / AppArmor 最小放宽

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

stage_begin "selinux_relax"
require_root

BACKUP_DIR="$(ensure_backup_dir selinux)"

SELINUX_STATUS="disabled"
if [[ -f /sys/fs/selinux/enforce ]]; then
    SELINUX_ENFORCE="$(cat /sys/fs/selinux/enforce 2>/dev/null || echo 0)"
    if [[ "${SELINUX_ENFORCE}" == "1" ]]; then SELINUX_STATUS="enforcing"
    else SELINUX_STATUS="permissive"; fi
fi
info "SELinux 状态：${SELINUX_STATUS}"

if [[ "${SELINUX_STATUS}" == "disabled" ]]; then
    info "SELinux 未启用，跳过"
    stage_end "selinux_relax"
    exit "${EX_OK}"
fi

have_semanage=0; have_setsebool=0
command -v semanage >/dev/null 2>&1 && have_semanage=1
command -v setsebool >/dev/null 2>&1 && have_setsebool=1
if [[ "${have_semanage}" -eq 0 ]]; then
    warn "未找到 semanage，尝试安装 policycoreutils-python-utils"
    if have_cmd dnf; then
        run dnf -y install policycoreutils-python-utils 2>&1 | tee -a "${LOG_FILE}" || true
        command -v semanage >/dev/null 2>&1 && have_semanage=1
    elif have_cmd yum; then
        run yum -y install policycoreutils-python-utils 2>&1 | tee -a "${LOG_FILE}" || true
        command -v semanage >/dev/null 2>&1 && have_semanage=1
    fi
fi

if [[ "${have_semanage}" -eq 1 ]]; then
    info "设置 /var/lib/mysql 上下文：mysqld_db_t"
    if is_dry_run; then
        echo "[DRY-RUN] semanage fcontext -a -t mysqld_db_t '/var/lib/mysql(/.*)?'"
    else
        local fctx_list; fctx_list="$(mktemp)"
        if semanage fcontext -l > "${fctx_list}" 2>/dev/null; then
            if grep -q '/var/lib/mysql(/.*)?.*mysqld_db_t' "${fctx_list}"; then
                info "/var/lib/mysql context 已配置"
            else
                semanage fcontext -a -t mysqld_db_t '/var/lib/mysql(/.*)?' 2>&1 | tee -a "${LOG_FILE}" \
                    || warn "semanage fcontext 失败"
            fi
        else
            warn "semanage fcontext -l 失败"
            semanage fcontext -a -t mysqld_db_t '/var/lib/mysql(/.*)?' 2>&1 | tee -a "${LOG_FILE}" \
                || warn "semanage fcontext 失败"
        fi
        rm -f "${fctx_list}"
        run restorecon -R /var/lib/mysql || warn "restorecon 失败"
    fi

    if [[ "${MYSQL_PORT}" != "3306" ]]; then
        info "注册 MySQL 端口 ${MYSQL_PORT} 到 mysqld_port_t"
        if ! is_dry_run; then
            semanage port -a -t mysqld_port_t -p tcp "${MYSQL_PORT}" 2>&1 | tee -a "${LOG_FILE}" \
                || warn "semanage port 失败"
        fi
    fi

    if [[ "${TOMCAT_PORT}" != "8080" && "${TOMCAT_PORT}" != "8443" ]]; then
        info "注册 Tomcat 端口 ${TOMCAT_PORT} 到 http_port_t"
        if ! is_dry_run; then
            semanage port -a -t http_port_t -p tcp "${TOMCAT_PORT}" 2>&1 | tee -a "${LOG_FILE}" \
                || warn "semanage port 失败"
        fi
    fi
fi

if [[ "${SELINUX_STATUS}" == "enforcing" ]]; then
    info "将 mysqld_t 与 tomcat_t 域切换为 permissive（最小放宽）"
    cat > /tmp/tomcat_permissive.te <<EOF
module tomcat_permissive 1.0;
require { type tomcat_t; }
type tomcat_permissive_t;
permissive tomcat_t;
EOF
    if ! is_dry_run; then
        if command -v checkmodule >/dev/null 2>&1 && command -v semodule_package >/dev/null 2>&1; then
            cd /tmp
            checkmodule -M -m -o tomcat_permissive.mod tomcat_permissive.te 2>&1 | tee -a "${LOG_FILE}" || true
            semodule_package -o tomcat_permissive.pp -m tomcat_permissive.mod 2>&1 | tee -a "${LOG_FILE}" || true
            run semodule -i tomcat_permissive.pp 2>&1 | tee -a "${LOG_FILE}" || warn "semodule 失败"
        else
            warn "checkmodule / semodule_package 缺失"
            if have_cmd dnf; then
                dnf -y install policycoreutils-devel 2>&1 | tee -a "${LOG_FILE}" || true
            fi
        fi

        local perm_list; perm_list="$(mktemp)"
        if semanage permissive -l > "${perm_list}" 2>/dev/null; then
            if ! grep -q '^mysqld_t$' "${perm_list}"; then
                run semanage permissive -a mysqld_t 2>&1 | tee -a "${LOG_FILE}" \
                    || warn "semanage permissive mysqld_t 失败"
            else
                info "mysqld_t 已是 permissive"
            fi
            if ! grep -q '^tomcat_t$' "${perm_list}"; then
                run semanage permissive -a tomcat_t 2>&1 | tee -a "${LOG_FILE}" \
                    || warn "semanage permissive tomcat_t 失败"
            fi
        else
            warn "semanage permissive -l 失败"
            run semanage permissive -a mysqld_t 2>&1 | tee -a "${LOG_FILE}" \
                || warn "semanage permissive mysqld_t 失败"
        fi
        rm -f "${perm_list}"
    fi
fi

if command -v aa-status >/dev/null 2>&1; then
    AA_STATUS="$(aa-status --enabled 2>/dev/null || echo disabled)"
    if [[ "${AA_STATUS}" == "enabled" ]]; then
        info "AppArmor 已启用，将 tomcat 配置为 complain 模式"
        if command -v aa-complain >/dev/null 2>&1; then
            if [[ -d "${TARGET_TOMCAT_DIR}" ]]; then
                if ! is_dry_run; then
                    run aa-complain "${TARGET_TOMCAT_DIR}" 2>&1 | tee -a "${LOG_FILE}" || warn "aa-complain 失败"
                fi
            fi
        else
            warn "aa-complain 未安装"
        fi
    fi
fi

ok "SELinux/AppArmor 策略调整完成（最小放宽原则）"
info "备份位置：${BACKUP_DIR}"
stage_end "selinux_relax"
exit "${EX_OK}"