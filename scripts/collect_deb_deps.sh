#!/usr/bin/env bash
# collect_deb_deps.sh - 离线采集 deb 依赖白名单
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

FAMILY="${TARGET_FAMILY:-$(auto_detect_family)}"
ARCH_VAL="${TARGET_ARCH:-$(auto_detect_arch)}"
WHITELIST="${PKG_DIR}/${FAMILY}/${ARCH_VAL}/debs/.deps_whitelist"

mkdir -p "$(dirname "${WHITELIST}")"
[[ -f "${WHITELIST}" ]] || cat > "${WHITELIST}" <<EOF
# deb 依赖白名单（一行一个）
libc6
libgcc-s1
libstdc++6
libaio1
libncurses6
libssl3
EOF
ok "白名单：${WHITELIST}（按需编辑后跑 dpkg -i *.deb）"