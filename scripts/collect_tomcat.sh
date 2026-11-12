#!/usr/bin/env bash
# collect_tomcat.sh - 采集 Tomcat 9 tar.gz（硬性要求 9 系列，10.x/11.x 一律拒绝）

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

FAMILY="${TARGET_FAMILY:-$(auto_detect_family)}"
ARCH_VAL="${TARGET_ARCH:-$(auto_detect_arch)}"
case "${ARCH_VAL}" in
    x86_64|aarch64) : ;;
    *) die "${EX_USAGE}" "仅支持 x86_64 / aarch64（Tomcat 本身跨架构，此限制与 JDK/MySQL 对齐），当前架构：${ARCH_VAL}" ;;
esac

OUT_DIR="${PKG_DIR}/${FAMILY}/${ARCH_VAL}/tomcat"
mkdir -p "${OUT_DIR}"

# 版本硬性要求：Tomcat 9.x（可用环境变量 TOMCAT_VERSION 覆盖小版本，仍必须在 9 系列内）
TOMCAT_VERSION="${TOMCAT_VERSION:-9.0.91}"
case "${TOMCAT_VERSION}" in
    9.*) : ;;
    *) die "${EX_USAGE}" "Tomcat 版本硬性要求 9 系列，当前配置：${TOMCAT_VERSION}" ;;
esac

# 双重校验：文件名 + tarball 顶层目录都必须是 tomcat 9 系列
# gzip -t 全量完整性校验（残卷/截断包必失败）
check_tomcat_tarball() {
    local f="$1"
    local base; base="$(basename "${f}")"
    case "${base}" in
        apache-tomcat-9.*|tomcat-9.*) : ;;
        *) err "Tomcat 硬性要求 9 系列，拒绝收录：${base}"; return 1 ;;
    esac
    if ! gzip -t "${f}" 2>/dev/null; then
        err "tarball 不完整（gzip 校验失败）：${base}"
        return 1
    fi
    local top
    top="$(tar -tf "${f}" 2>/dev/null | head -n1 || true)"
    case "${top}" in
        apache-tomcat-9.*|tomcat-9.*) : ;;
        *) err "tarball 内容与 9 系列不符（顶层目录：${top:-无法识别}），拒绝收录：${base}"; return 1 ;;
    esac
    return 0
}

# 本地优先（仍须满足 9 系列，不符合则直接报错退出，不静默收录）
for cand in "${HOME}/apache-tomcat"*.tar.gz /opt/apache-tomcat*.tar.gz /usr/local/apache-tomcat*.tar.gz; do
    if [[ -f "${cand}" ]]; then
        if check_tomcat_tarball "${cand}"; then
            cp -n "${cand}" "${OUT_DIR}/"
            info "已复制本地 Tomcat: ${cand}"
            exit 0
        else
            die "${EX_USAGE}" "本地 Tomcat 包不符合 9 系列硬性要求，请替换为 apache-tomcat-9.x tarball 后重试"
        fi
    fi
done

# 已有完整包则跳过（gzip 全量校验）
EXISTING="$(find "${OUT_DIR}" -maxdepth 1 -type f -name '*.tar.gz' -size +5M 2>/dev/null | head -n1)"
if [[ -n "${EXISTING}" ]] && gzip -t "${EXISTING}" 2>/dev/null; then
    ok "Tomcat 已存在且校验通过，跳过下载：${EXISTING}"
    exit 0
fi

REL_PATH="tomcat/tomcat-9/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz"
OUT_FILE="${OUT_DIR}/apache-tomcat-${TOMCAT_VERSION}.tar.gz"
info "下载 Tomcat ${TOMCAT_VERSION}（断点续传，最多 3 轮重试）"
# 国内镜像优先（阿里云），archive.apache.org 兜底
URLS=(
    "https://mirrors.aliyun.com/apache/${REL_PATH}"
    "https://archive.apache.org/dist/${REL_PATH}"
)
DL_OK=0
for url in "${URLS[@]}"; do
    for _try in 1 2 3; do
        if curl -fsSL --retry 2 --retry-delay 3 -C - "${url}" -o "${OUT_FILE}" \
            && check_tomcat_tarball "${OUT_FILE}"; then
            DL_OK=1
            break 2
        fi
        warn "下载中断（${url} 第 ${_try}/3 轮），断点续传重试中..."
        sleep 3
    done
done
if [[ "${DL_OK}" -ne 1 ]]; then
    warn "下载失败（需人工准备 apache-tomcat-9.x tarball 放到 ${OUT_DIR}/）"
    exit 0
fi
ok "Tomcat 已就绪：${OUT_FILE}"
