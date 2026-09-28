#!/usr/bin/env bash
# firewall.sh - firewalld / ufw / iptables 三态自适应

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

stage_begin "firewall"
require_root

BACKUP_DIR="$(ensure_backup_dir firewall)"

handle_firewalld() {
    if ! command -v firewall-cmd >/dev/null 2>&1; then return 0; fi
    if ! systemctl is-active --quiet firewalld 2>/dev/null; then
        info "firewalld 未运行，跳过"; return 0
    fi
    info "firewalld 运行中 → 添加端口"
    local services_added=(); local ports_added=()
    if [[ "${SKIP_MYSQL}" -eq 0 ]]; then
        if [[ "${MYSQL_PORT}" == "3306" ]]; then
            if ! firewall-cmd --query-service=mysql >/dev/null 2>&1; then
                run firewall-cmd --permanent --add-service=mysql 2>&1 | tee -a "${LOG_FILE}" \
                    && services_added+=("mysql")
            fi
        else
            if ! firewall-cmd --query-port="${MYSQL_PORT}/tcp" >/dev/null 2>&1; then
                run firewall-cmd --permanent --add-port="${MYSQL_PORT}/tcp" 2>&1 | tee -a "${LOG_FILE}" \
                    && ports_added+=("${MYSQL_PORT}/tcp")
            fi
        fi
    fi
    if [[ "${SKIP_TOMCAT}" -eq 0 ]]; then
        local tport="${TOMCAT_PORT}"
        if ! firewall-cmd --query-port="${tport}/tcp" >/dev/null 2>&1; then
            run firewall-cmd --permanent --add-port="${tport}/tcp" 2>&1 | tee -a "${LOG_FILE}" \
                && ports_added+=("${tport}/tcp")
        fi
    fi
    if [[ ${#services_added[@]} -gt 0 || ${#ports_added[@]} -gt 0 ]]; then
        run firewall-cmd --reload 2>&1 | tee -a "${LOG_FILE}" \
            && ok "firewalld 已重载" \
            || warn "firewalld reload 失败"
        info "新增服务：${services_added[*]:-（无）}"
        info "新增端口：${ports_added[*]:-（无）}"
    fi
}

handle_ufw() {
    if ! command -v ufw >/dev/null 2>&1; then return 0; fi
    local status; status="$(ufw status 2>/dev/null | head -n1 || echo unknown)"
    if [[ "${status}" != *"active"* ]]; then info "ufw 未启用，跳过"; return 0; fi
    info "ufw 启用中 → 添加规则"
    local ports_added=()
    if [[ "${SKIP_MYSQL}" -eq 0 ]]; then
        if ! ufw status | grep -qE " ${MYSQL_PORT}/tcp"; then
            if ! is_dry_run; then
                run ufw allow "${MYSQL_PORT}/tcp" 2>&1 | tee -a "${LOG_FILE}" \
                    && ports_added+=("${MYSQL_PORT}/tcp")
            fi
        fi
    fi
    if [[ "${SKIP_TOMCAT}" -eq 0 ]]; then
        if ! ufw status | grep -qE " ${TOMCAT_PORT}/tcp"; then
            if ! is_dry_run; then
                run ufw allow "${TOMCAT_PORT}/tcp" 2>&1 | tee -a "${LOG_FILE}" \
                    && ports_added+=("${TOMCAT_PORT}/tcp")
            fi
        fi
    fi
    if [[ ${#ports_added[@]} -gt 0 ]]; then ok "ufw 已添加：${ports_added[*]}"; fi
}

handle_iptables() {
    if ! command -v iptables >/dev/null 2>&1; then return 0; fi
    if systemctl is-active --quiet firewalld 2>/dev/null; then info "firewalld 在管，跳过 iptables"; return 0; fi
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        info "ufw 在管，跳过 iptables"; return 0
    fi
    info "iptables 兜底放行"
    if [[ "${SKIP_MYSQL}" -eq 0 ]]; then
        if ! iptables -C INPUT -p tcp --dport "${MYSQL_PORT}" -j ACCEPT 2>/dev/null; then
            if ! is_dry_run; then
                run iptables -I INPUT -p tcp --dport "${MYSQL_PORT}" -j ACCEPT 2>&1 | tee -a "${LOG_FILE}" \
                    && ok "iptables 已放行 ${MYSQL_PORT}"
                if command -v service >/dev/null && service iptables save >/dev/null 2>&1; then
                    run service iptables save 2>&1 | tee -a "${LOG_FILE}" || true
                elif [[ -d /etc/iptables ]]; then
                    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
                fi
            fi
        fi
    fi
    if [[ "${SKIP_TOMCAT}" -eq 0 ]]; then
        if ! iptables -C INPUT -p tcp --dport "${TOMCAT_PORT}" -j ACCEPT 2>/dev/null; then
            if ! is_dry_run; then
                run iptables -I INPUT -p tcp --dport "${TOMCAT_PORT}" -j ACCEPT 2>&1 | tee -a "${LOG_FILE}" \
                    && ok "iptables 已放行 ${TOMCAT_PORT}"
            fi
        fi
    fi
}

handle_firewalld
handle_ufw
handle_iptables

ok "防火墙策略调整完成（最小放行）"
info "备份位置：${BACKUP_DIR}"
stage_end "firewall"
exit "${EX_OK}"