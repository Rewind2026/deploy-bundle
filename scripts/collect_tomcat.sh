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

# 双重校验：以包内容（tar 顶层目录）识别真实版本，文件名不做要求——
# 现场投喂的包可能叫 tomcat.zip、tomcat-test.tar.gz 等任意名字，实际是 9.0.132 也照样收录；
# gzip -t / unzip -t 全量完整性校验（残卷/截断包必失败）
check_tomcat_tarball() {
    local f="$1"
    case "${f}" in
        *.zip)
            if have_cmd unzip; then
                unzip -tqq "${f}" >/dev/null 2>&1 || { err "zip 归档不完整（unzip 校验失败）：$(basename "${f}")"; return 1; }
            elif have_cmd python3; then
                python3 -c 'import sys, zipfile
sys.exit(1 if zipfile.ZipFile(sys.argv[1]).testzip() else 0)' "${f}" 2>/dev/null \
                    || { err "zip 归档不完整（python 校验失败）：$(basename "${f}")"; return 1; }
            else
                err "缺少 unzip/python3，无法校验 .zip 包（可用 tar.gz 代替）：$(basename "${f}")"
                return 1
            fi
            ;;
        *)
            gzip -t "${f}" 2>/dev/null || { err "tarball 不完整（gzip 校验失败）：$(basename "${f}")"; return 1; }
            ;;
    esac
    local top
    top="$(archive_top_entry "${f}")"
    top="${top#./}"
    case "${top}" in
        apache-tomcat-9.*|tomcat-9.*) : ;;
        *) err "Tomcat 硬性要求 9 系列（包内容顶层目录：${top:-无法识别}），拒绝收录：$(basename "${f}")"; return 1 ;;
    esac
    return 0
}

# 从归档内容提取具体版本号（如 9.0.132），仅用于日志展示
tomcat_version_of() {
    local top
    top="$(archive_top_entry "$1")"
    printf '%s' "${top}" | grep -oE '9\.[0-9]+(\.[0-9]+)?' | head -n1 || true
}

# 本地优先（仍须满足 9 系列，不符合则直接报错退出，不静默收录）。
# 文件名任意（tomcat.zip、apache-tomcat-*.tar.gz 均可），版本以包内容为准。
shopt -s nullglob
for d in "${HOME}" /opt /usr/local; do
    for cand in "${d}"/apache-tomcat*.tar.gz "${d}"/apache-tomcat*.zip \
                "${d}"/tomcat*.tar.gz "${d}"/tomcat*.zip; do
        [[ -f "${cand}" ]] || continue
        if check_tomcat_tarball "${cand}"; then
            cp -n "${cand}" "${OUT_DIR}/"
            info "已复制本地 Tomcat: ${cand}（包内实际版本：$(tomcat_version_of "${cand}" || echo 未知)）"
            exit 0
        else
            die "${EX_USAGE}" "本地 Tomcat 包不符合 9 系列硬性要求，请替换为 apache-tomcat-9.x 归档后重试：${cand}"
        fi
    done
done
shopt -u nullglob

# 已有完整包则跳过（以包内容校验，文件名任意）
EXISTING="$(find "${OUT_DIR}" -maxdepth 1 -type f \( -name '*.tar.gz' -o -name '*.zip' \) -size +5M 2>/dev/null | head -n1)"
if [[ -n "${EXISTING}" ]] && check_tomcat_tarball "${EXISTING}"; then
    ok "Tomcat 已存在且校验通过，跳过下载：${EXISTING}（包内实际版本：$(tomcat_version_of "${EXISTING}" || echo 未知)）"
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
        _ec=0
        curl -fsSL --retry 2 --retry-delay 3 -C - "${url}" -o "${OUT_FILE}" && _ec=0 || _ec=$?
        if [[ ${_ec} -eq 0 ]] && check_tomcat_tarball "${OUT_FILE}"; then
            DL_OK=1
            break 2
        fi
        # 退出码 22 = HTTP 错误（如 404）：镜像站只保留各大版本的最新发布版，
        # 旧版本（如 9.0.91）只在 archive.apache.org 上存在，重试必然还是 404，
        # 立即换下一个 URL；其余退出码（超时/传输中断）才是值得断点续传的暂态错误。
        if [[ ${_ec} -eq 22 ]]; then
            warn "${url} 返回 HTTP 错误（该镜像无此版本，属永久性 404），换下一个源"
            break
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
