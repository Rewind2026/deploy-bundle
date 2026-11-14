#!/usr/bin/env bash
# collect.sh - 一键采集入口
# 聚合：JDK / MySQL 8.4.x（双 glibc）/ Tomcat 9 / 系统依赖（rpm 或 deb）

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

FAMILY="${TARGET_FAMILY:-$(auto_detect_family)}"
ARCH_VAL="${TARGET_ARCH:-$(auto_detect_arch)}"
case "${ARCH_VAL}" in
    x86_64|aarch64) : ;;
    *) die "${EX_USAGE}" "仅支持 x86_64 / aarch64，当前架构：${ARCH_VAL}" ;;
esac
if [[ -z "${TARGET_FAMILY:-}" ]]; then
    info "未指定 TARGET_FAMILY，已自动探测本机系统"
    info "注意：自动探测结果代表『运行本脚本的机器』。若离线客户机与本机系统不同，请改用 TARGET_FAMILY=<family> TARGET_ARCH=<arch> 重新采集"
fi
info "采集目标：FAMILY=${FAMILY}  ARCH=${ARCH_VAL}"
info "可选 family：rhel7-line / rhel8-line / openeuler-line / deb-line（对应麒麟 V10 SP1 / 麒麟 V10 SP2+、UOS 1050/1060 / openEuler、麒麟 V11、UOS Server 23+ / 麒麟桌面版等，详见 docs/COMPATIBILITY.md）"

"${SCRIPT_DIR}/collect_jdk.sh"
"${SCRIPT_DIR}/collect_mysql.sh"
"${SCRIPT_DIR}/collect_tomcat.sh"

# 系统依赖采集（libaio/libnuma/ncurses 等 MySQL 运行必需）
case "${FAMILY}" in
    deb-line)
        "${SCRIPT_DIR}/collect_deb_deps.sh" || warn "deb 依赖采集失败，请人工补充 debs/"
        ;;
    *)
        "${SCRIPT_DIR}/collect_rpm_deps.sh" || warn "rpm 依赖采集失败，请人工补充 rpms/"
        ;;
esac

ok "采集完成；离线包位于 packages/${FAMILY}/${ARCH_VAL}/"
