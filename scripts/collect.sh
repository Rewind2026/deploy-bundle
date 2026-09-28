#!/usr/bin/env bash
# collect.sh - 一键采集入口（聚合 collect_jdk / collect_mysql / collect_tomcat）

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

FAMILY="${TARGET_FAMILY:-$(auto_detect_family)}"
ARCH_VAL="${TARGET_ARCH:-$(auto_detect_arch)}"
info "采集目标：FAMILY=${FAMILY}  ARCH=${ARCH_VAL}"

"${SCRIPT_DIR}/collect_jdk.sh"
"${SCRIPT_DIR}/collect_mysql.sh"
"${SCRIPT_DIR}/collect_tomcat.sh"

ok "采集完成；离线包位于 packages/${FAMILY}/${ARCH_VAL}/"