#!/usr/bin/env bash
# collect_tomcat.sh - 采集 Tomcat 9 tar.gz

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

FAMILY="${TARGET_FAMILY:-$(auto_detect_family)}"
ARCH_VAL="${TARGET_ARCH:-$(auto_detect_arch)}"

OUT_DIR="${PKG_DIR}/${FAMILY}/${ARCH_VAL}/tomcat"
mkdir -p "${OUT_DIR}"

# 本地优先
TMP_LIST="$(mktemp)"
for cand in "${HOME}/apache-tomcat"*.tar.gz /opt/apache-tomcat*.tar.gz /usr/local/apache-tomcat*.tar.gz; do
    [[ -f "${cand}" ]] && { cp -n "${cand}" "${OUT_DIR}/"; echo "${cand}" > "${TMP_LIST}"; info "已复制本地 Tomcat: ${cand}"; rm -f "${TMP_LIST}"; exit 0; }
done
rm -f "${TMP_LIST}"

VER="9.0.91"
URL_BASE="https://archive.apache.org/dist/tomcat/tomcat-9/v${VER}/bin/apache-tomcat-${VER}.tar.gz"
info "尝试从 archive.apache.org 下载 Tomcat ${VER}"

TMP="$(mktemp -d)"
curl -fsSL "${URL_BASE}" -o "${TMP}/tomcat.tar.gz" || { warn "下载失败（需人工准备 tarball 放到 ${OUT_DIR}/）"; exit 0; }
mv "${TMP}/tomcat.tar.gz" "${OUT_DIR}/"
rm -rf "${TMP}"
ok "Tomcat 已就绪：${OUT_DIR}/"