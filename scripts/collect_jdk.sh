#!/usr/bin/env bash
# collect_jdk.sh - 采集 JDK 8 tar.gz

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

FAMILY="${TARGET_FAMILY:-$(auto_detect_family)}"
ARCH_VAL="${TARGET_ARCH:-$(auto_detect_arch)}"

OUT_DIR="${PKG_DIR}/${FAMILY}/${ARCH_VAL}/jdk"
mkdir -p "${OUT_DIR}"

# 优先使用本地已有的 JDK tarball
for cand in "${HOME}/jdk"*.tar.gz /opt/jdk*.tar.gz /usr/local/jdk*.tar.gz; do
    [[ -f "${cand}" ]] && { cp -n "${cand}" "${OUT_DIR}/"; info "已复制本地 JDK: ${cand}"; exit 0; }
done

# 退化：从 Adoptium 下载（仅限镜像机联网时）
URL_BASE="https://api.adoptium.net/v3/binary/latest/8/ga/${ARCH_VAL}/jdk/hotspot/normal/eclipse"
info "从 Adoptium 下载 JDK 8（仅镜像机）"
TMP="$(mktemp -d)"
curl -fsSL "${URL_BASE}" -o "${TMP}/jdk.tar.gz" || { warn "下载失败（非联网镜像机，跳过；需人工把 tar 包放到 ${OUT_DIR}/）"; exit 0; }
mv "${TMP}/jdk.tar.gz" "${OUT_DIR}/"
rm -rf "${TMP}"
ok "JDK 已就绪：${OUT_DIR}/"