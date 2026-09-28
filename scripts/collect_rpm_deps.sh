#!/usr/bin/env bash
# collect_rpm_deps.sh - 离线采集 rpm 依赖白名单
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

FAMILY="${TARGET_FAMILY:-$(auto_detect_family)}"
ARCH_VAL="${TARGET_ARCH:-$(auto_detect_arch)}"
WHITELIST="${PKG_DIR}/${FAMILY}/${ARCH_VAL}/rpms/.deps_whitelist"

mkdir -p "$(dirname "${WHITELIST}")"
[[ -f "${WHITELIST}" ]] || cat > "${WHITELIST}" <<EOF
# rpm 依赖白名单
libaio
numactl-libs
ncurses-compat-libs
openssl
EOF
ok "白名单：${WHITELIST}（按需编辑后跑 rpm -Uvh *.rpm）"