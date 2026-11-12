id: /root/.trae-cn-server/bin/stable-d654d294a690adb43b5bb35d5b37adf9f292cee0-debian10/modules/ai-agent/libselinux.so.1: no version information available (required by id)
#!/usr/bin/env bash
# firewall.sh - 永久关闭防火墙（firewalld / ufw / iptables / nftables 自适应）
# 背景：Tomcat/MySQL 端口可能现场调整，固定放行规则无法维护；
# 离线内网环境按交付约定直接永久关闭防火墙。
# 如需保留防火墙现状，部署时加 --skip-firewall 跳过本阶段。

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

stage_begin "firewall"
require_root

BACKUP_DIR="$(ensure_backup_dir firewall)"

handle_firewalld() {
    # 未安装 firewalld 直接跳过。
    # 注意：不要写 "systemctl list-unit-files | grep -q" —— pipefail 下 grep -q
    # 提前退出会让 systemctl 收到 SIGPIPE，整条管道非零，误触发 return 0。
    [[ "$(systemctl list-unit-files 2>/dev/null | grep -c '^firewalld\.service')" -ge 1 ]] || return 0
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        info "永久关闭 firewalld（stop + disable）"
        if ! is_dry_run; then
            run systemctl stop firewalld 2>&1 | tee -a "${LOG_FILE}" || warn "stop firewalld 失败"
        fi
    fi
    if ! is_dry_run; then
        run systemctl disable firewalld 2>&1 | tee -a "${LOG_FILE}" || warn "disable firewalld 失败"
        ok "firewalld 已永久关闭"
    fi
}

handle_ufw() {
    command -v ufw >/dev/null 2>&1 || return 0
    [[ "$(ufw status 2>/dev/null | head -n1)" == *"Status: active"* ]] || return 0
    info "永久关闭 ufw"
    if ! is_dry_run; then
        run ufw disable 2>&1 | tee -a "${LOG_FILE}" || warn "ufw disable 失败"
        ok "ufw 已永久关闭"
    fi
}

handle_iptables() {
    command -v iptables >/dev/null 2>&1 || return 0
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        info "firewalld 在管（已关闭），跳过 iptables"
        return 0
    fi
    if command -v ufw >/dev/null 2>&1 && [[ "$(ufw status 2>/dev/null)" == *"Status: active"* ]]; then
        info "ufw 在管（已关闭），跳过 iptables"
        return 0
    fi
    info "清空 iptables INPUT 过滤规则并持久化"
    if ! is_dry_run; then
        run iptables -F INPUT 2>&1 | tee -a "${LOG_FILE}" || warn "iptables -F INPUT 失败"
        if command -v service >/dev/null && service iptables save >/dev/null 2>&1; then
            run service iptables save 2>&1 | tee -a "${LOG_FILE}" || true
        elif [[ -d /etc/iptables ]]; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
        ok "iptables INPUT 规则已清空"
    fi
}

handle_nftables() {
    systemctl is-active --quiet nftables 2>/dev/null || return 0
    info "永久关闭 nftables（stop + disable）"
    if ! is_dry_run; then
        run systemctl stop nftables 2>&1 | tee -a "${LOG_FILE}" || warn "stop nftables 失败"
        run systemctl disable nftables 2>&1 | tee -a "${LOG_FILE}" || warn "disable nftables 失败"
        ok "nftables 已永久关闭"
    fi
}

handle_firewalld
handle_ufw
handle_iptables
handle_nftables

ok "防火墙已永久关闭（如需保留防火墙，请用 --skip-firewall）"
info "备份位置：${BACKUP_DIR}"
stage_end "firewall"
exit "${EX_OK}"
