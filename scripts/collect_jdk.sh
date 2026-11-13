#!/usr/bin/env bash
# collect_jdk.sh - 采集 JDK 8 tar.gz

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

FAMILY="${TARGET_FAMILY:-$(auto_detect_family)}"
ARCH_VAL="${TARGET_ARCH:-$(auto_detect_arch)}"
case "${ARCH_VAL}" in
    x86_64|aarch64) : ;;
    *) die "${EX_USAGE}" "仅支持 x86_64 / aarch64，当前架构：${ARCH_VAL}" ;;
esac

OUT_DIR="${PKG_DIR}/${FAMILY}/${ARCH_VAL}/jdk"
mkdir -p "${OUT_DIR}"

# 优先使用本地已有的 JDK tarball
for cand in "${HOME}/jdk"*.tar.gz /opt/jdk*.tar.gz /usr/local/jdk*.tar.gz; do
    [[ -f "${cand}" ]] && { cp -n "${cand}" "${OUT_DIR}/"; info "已复制本地 JDK: ${cand}"; exit 0; }
done

# JDK 版本硬性要求 1.8.x（可用 JDK_VERSION 覆盖小版本，仍必须在 8 系列内）
JDK_VERSION="${JDK_VERSION:-8}"
case "${JDK_VERSION}" in
    8|8.*|1.8|1.8.*) : ;;
    *) die "${EX_USAGE}" "JDK 版本硬性要求 1.8.x（Tomcat 9 + GC 参数均按 JDK 8 适配），当前配置：${JDK_VERSION}" ;;
esac

# Adoptium API 架构参数为 x64/aarch64，与 uname -m (x86_64) 不同
case "${ARCH_VAL}" in
    x86_64)  API_ARCH="x64" ;;
    aarch64) API_ARCH="aarch64" ;;
    *)       API_ARCH="${ARCH_VAL}" ;;
esac

# 退化：从 Adoptium 下载（仅限镜像机联网时）
# Adoptium API v3 binary 路径：/v3/binary/latest/{version}/{release_type}/{os}/{arch}/{image_type}/{project}/{vendor}
URL_BASE="https://api.adoptium.net/v3/binary/latest/${JDK_VERSION}/ga/linux/${API_ARCH}/jdk/hotspot/normal/eclipse"

# 已有完整包则跳过（gzip 全量校验；残卷 <50MB 或校验失败都会触发重新下载/续传）
EXISTING="$(find "${OUT_DIR}" -maxdepth 1 -type f \( -name '*.tar.gz' -o -name '*.tgz' \) -size +50M 2>/dev/null | head -n1)"
if [[ -n "${EXISTING}" ]] && gzip -t "${EXISTING}" 2>/dev/null; then
    ok "JDK 已存在且校验通过，跳过下载：${EXISTING}"
    exit 0
fi

info "从 Adoptium 下载 JDK 8（仅镜像机）"
# 注意：-C -（断点续传）与 -J（Content-Disposition 命名）在 curl 中互斥，
# 故先解析 307 重定向后的最终 URL 取文件名。GitHub 最终跳到 release-assets CDN，
# 真实文件名在 query 参数 filename%3Dxxx.tar.gz 中
FINAL_URL="$(curl -fsSL -o /dev/null --max-time 60 -w '%{url_effective}' "${URL_BASE}" || true)"
# 注意：Adoptium 不可达时 FINAL_URL 为空，grep 无匹配返回非 0，
# 在 set -o pipefail 下会直接杀死脚本（2026-11-13 实测 Kylin V11 上复现），故追加 || true
FNAME="$(printf '%s' "${FINAL_URL:-}" | grep -oE 'filename%3D[A-Za-z0-9._-]+\.tar\.gz' | head -n1 | sed 's/^filename%3D//' || true)"
[[ -n "${FNAME}" ]] || FNAME="$(basename "${FINAL_URL:-}")"
[[ "${FNAME}" =~ \.tar\.gz$ ]] || FNAME="jdk${JDK_VERSION}-linux-${API_ARCH}.tar.gz"
info "目标文件名：${FNAME}"
# 国内到 GitHub 链路易断连，最多重试 3 次，-C - 断点续传
DL_OK=0
for _try in 1 2 3; do
    curl -fsL --retry 2 --retry-delay 3 -C - "${URL_BASE}" -o "${OUT_DIR}/${FNAME}" && DL_OK=1 && break
    warn "JDK 下载中断（第 ${_try}/3 次），断点续传重试中..."
    sleep 3
done
if [[ "${DL_OK}" -ne 1 ]]; then
    warn "下载失败（非联网镜像机，跳过；需人工把 tar 包放到 ${OUT_DIR}/）"
    exit 0
fi
ok "JDK 已就绪：${OUT_DIR}/${FNAME}"