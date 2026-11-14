#!/usr/bin/env bash
# detect.sh - 只读系统探测报告（不下载、不安装、不改动任何东西）
# 用途：拿到一台新系统（尤其是国产化 OS 新版本/小版本）时，先跑这个，
#       确认它被归到哪个 family、该用哪份 packages/<family>/<arch>。
# 输出：OS 身份文件 → family / arch / glibc → 本地离线包目录状态

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

ARCH_VAL="${TARGET_ARCH:-$(auto_detect_arch)}"
FAMILY="${TARGET_FAMILY:-$(auto_detect_family)}"

echo "================ 系统探测报告 ================"
echo "[OS 身份文件]"
if [[ -f /etc/os-release ]]; then
    grep -E '^(NAME|ID|ID_LIKE|VERSION_ID|VERSION)=' /etc/os-release | sed 's/^/    /'
else
    echo "    （无 /etc/os-release）"
fi
for f in /etc/.kyinfo /etc/os-version /usr/lib/os-version; do
    if [[ -f "${f}" ]]; then
        echo "    ${f}:"
        grep -E '^(name|milestone|Arch|major|minor|Version|Edition|osp_version)=' "${f}" 2>/dev/null | sed 's/^/        /'
    fi
done
echo "    内核：$(uname -r)"
echo "    架构：${ARCH_VAL}"
echo "    glibc：$(ldd --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+$' || echo 未知)"
echo "    包管理器：$(command -v apt-get >/dev/null 2>&1 && printf 'apt ' ; command -v dpkg >/dev/null 2>&1 && printf 'dpkg ' ; command -v dnf >/dev/null 2>&1 && printf 'dnf ' ; command -v yum >/dev/null 2>&1 && printf 'yum ' ; echo)"

echo "[归入 family]"
echo "    FAMILY=${FAMILY}  ARCH=${ARCH_VAL}"

echo "[离线包目录状态]"
PKG_BASE="${PKG_DIR:-${BUNDLE_ROOT:-/opt/deploy-bundle}/packages}"
TARGET_DIR="${PKG_BASE}/${FAMILY}/${ARCH_VAL}"
if [[ -d "${TARGET_DIR}" ]]; then
    for sub in jdk mysql tomcat rpms debs; do
        if [[ -d "${TARGET_DIR}/${sub}" ]]; then
            local_count="$(find "${TARGET_DIR}/${sub}" -maxdepth 1 -type f 2>/dev/null | wc -l)"
            echo "    OK  ${TARGET_DIR}/${sub}（${local_count} 个文件）"
        else
            echo "    缺  ${TARGET_DIR}/${sub}"
        fi
    done
else
    echo "    ${TARGET_DIR} 不存在，尚未采集"
fi

echo "[family 速查]"
echo "    rhel7-line    : 麒麟 V10 SP1/SP2、CentOS/RHEL 7、openEuler 20.03（glibc 2.17）"
echo "    rhel8-line    : 麒麟 V10 SP3、CentOS/RHEL 8/9、Anolis、TencentOS（glibc 2.28）"
echo "    openeuler-line: openEuler 22.03/24.03、麒麟 V11、UOS Server 23/24/25（glibc 2.28+）"
echo "    deb-line      : Ubuntu/Debian/Deepin、麒麟桌面版、UOS 桌面版、openKylin（apt 系）"
echo "============================================="
info "若 family 不符合预期，可 TARGET_FAMILY=<family> bash scripts/detect.sh 强制验证；"
info "采集前请确认上面【归入 family】与【离线包目录状态】一致。"
