#!/usr/bin/env bash
# collect_mysql.sh - 采集 MySQL 8 tar.xz

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

FAMILY="${TARGET_FAMILY:-$(auto_detect_family)}"
ARCH_VAL="${TARGET_ARCH:-$(auto_detect_arch)}"

OUT_DIR="${PKG_DIR}/${FAMILY}/${ARCH_VAL}/mysql"
mkdir -p "${OUT_DIR}"

# 本地优先
for cand in "${HOME}/mysql"*.tar.xz /opt/mysql*.tar.xz /usr/local/mysql*.tar.xz; do
    [[ -f "${cand}" ]] && { cp -n "${cand}" "${OUT_DIR}/"; info "已复制本地 MySQL: ${cand}"; exit 0; }
done

# 探测本机 glibc 提示
HOST_GLIBC=""
if command -v ldd >/dev/null 2>&1; then
    HOST_GLIBC="$(ldd --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)"
fi

GLIBC_TAG="glibc2.28"
case "${HOST_GLIBC}" in
    2.17|2.18|2.19|2.20|2.21|2.22|2.23|2.24|2.25|2.26|2.27) GLIBC_TAG="glibc2.17" ;;
esac

VER="8.0.36"
URL_BASE="https://dev.mysql.com/get/Downloads/MySQL-8.0/mysql-${VER}-linux-${GLIBC_TAG}-${ARCH_VAL}.tar.xz"
info "尝试从 dev.mysql.com 下载 MySQL ${VER} (${GLIBC_TAG}/${ARCH_VAL})"

TMP="$(mktemp -d)"
curl -fsSL "${URL_BASE}" -o "${TMP}/mysql.tar.xz" || { warn "下载失败（aarch64/loongarch64 无官方包，需人工准备 tarball 放到 ${OUT_DIR}/）"; exit 0; }
mv "${TMP}/mysql.tar.xz" "${OUT_DIR}/"
rm -rf "${TMP}"
ok "MySQL 已就绪：${OUT_DIR}/"