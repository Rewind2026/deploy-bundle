#!/usr/bin/env bash
# detect_kylin_uos.sh - 麒麟 Kylin / 统信 UOS 专项探测
# 输出 8 个全局变量：KYLIN_UOS_OS / VARIANT / FAMILY / GLIBC / KERNEL / CODENAME / MILESTONE / ARCH
# 全局变量（不能加 local）

set +e

KYLIN_UOS_OS=""
KYLIN_UOS_VARIANT=""
KYLIN_UOS_FAMILY=""
KYLIN_UOS_GLIBC=""
KYLIN_UOS_CODENAME=""
KYLIN_UOS_MILESTONE=""

# ---- 1. 麒麟 Kylin ----
if [[ -f /etc/.kyinfo ]]; then
    KYLIN_UOS_MILESTONE="$(awk -F= '/milestone/ {gsub(/[ \t]+$/,"",$2); print $2}' /etc/.kyinfo 2>/dev/null | head -n1)"
    [[ -z "${KYLIN_UOS_MILESTONE}" ]] && KYLIN_UOS_MILESTONE="$(grep -E '^milestone=' /etc/.kyinfo 2>/dev/null | head -n1 | cut -d= -f2-)"
    # dist name 形如 Kylin-Server-V11-2503；部分 V11 版本 milestone 不含 "V11" 字样（如 Release-General-20250715）
    KYLIN_UOS_DIST_NAME="$(awk -F= '/^name=/ {print $2}' /etc/.kyinfo 2>/dev/null | head -n1)"
fi

if [[ -n "${KYLIN_UOS_MILESTONE}" ]]; then
    _KYLIN_MS="${KYLIN_UOS_MILESTONE}"
    # 麒麟桌面版（V10/V11）与服务器版共用 /etc/.kyinfo，但桌面版是 deb 系（apt/dpkg），
    # 服务器版是 rpm 系（yum/dnf）。必须先按包管理器分家，再走版本→family 映射。
    _KYLIN_IS_DEB=0
    if command -v dpkg >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1 \
       && ! command -v dnf >/dev/null 2>&1 && ! command -v yum >/dev/null 2>&1; then
        _KYLIN_IS_DEB=1
    fi
    _KYLIN_SP=""
    _KYLIN_MS_TAIL=""
    _KYLIN_V11_MINOR=""

    # V11 识别：milestone 或 /etc/.kyinfo dist name 任一包含 V11
    if [[ "${_KYLIN_MS}" =~ V11-([0-9]+) ]]; then
        _KYLIN_V11_MINOR="${BASH_REMATCH[1]}"
    elif [[ "${KYLIN_UOS_DIST_NAME:-}" =~ V11-([0-9]+) ]]; then
        _KYLIN_V11_MINOR="${BASH_REMATCH[1]}"
    fi
    if [[ "${_KYLIN_MS}" =~ V10-?SP([0-9]+) ]]; then
        _KYLIN_SP="${BASH_REMATCH[1]}"
    fi
    if [[ "${_KYLIN_MS}" =~ Release-([0-9]+) ]]; then
        _KYLIN_MS_TAIL="${BASH_REMATCH[1]}"
    fi

    if [[ "${_KYLIN_IS_DEB}" == "1" ]]; then
        # 桌面版（deb 系）：V11 用 kylin-desktop-v11，其余归入 v10
        _KYLIN_DV="v10"
        [[ "${_KYLIN_MS}" == *"V11"* ]] && _KYLIN_DV="v11"
        KYLIN_UOS_OS="kylin-desktop-${_KYLIN_DV}"
        KYLIN_UOS_VARIANT="desktop"
        KYLIN_UOS_FAMILY="deb-line"
        KYLIN_UOS_GLIBC="28"
    elif [[ "${_KYLIN_MS}" == *"V11"* || "${KYLIN_UOS_DIST_NAME:-}" == *"V11"* ]]; then
        case "${_KYLIN_V11_MINOR}" in
            ""|unknown)
                KYLIN_UOS_OS="kylin-v11"
                KYLIN_UOS_FAMILY="openeuler-line"
                KYLIN_UOS_GLIBC="28"
                ;;
            *)
                KYLIN_UOS_OS="kylin-v11-${_KYLIN_V11_MINOR}"
                KYLIN_UOS_FAMILY="openeuler-line"
                KYLIN_UOS_GLIBC="28"
                ;;
        esac
    elif [[ "${_KYLIN_MS}" == *"V10"* ]]; then
        case "${_KYLIN_SP}" in
            1)
                KYLIN_UOS_OS="kylin-v10-sp1"
                KYLIN_UOS_FAMILY="rhel7-line"
                KYLIN_UOS_GLIBC="17"
                ;;
            2)
                KYLIN_UOS_OS="kylin-v10-sp2"
                KYLIN_UOS_FAMILY="rhel8-line"
                KYLIN_UOS_GLIBC="28"
                ;;
            3)
                KYLIN_UOS_OS="kylin-v10-sp3-${_KYLIN_MS_TAIL:-unknown}"
                KYLIN_UOS_FAMILY="rhel8-line"
                KYLIN_UOS_GLIBC="28"
                ;;
            *)
                KYLIN_UOS_OS="kylin-v10-${_KYLIN_SP:-unknown}"
                KYLIN_UOS_FAMILY="rhel8-line"
                KYLIN_UOS_GLIBC="28"
                ;;
        esac
    else
        KYLIN_UOS_OS="kylin-${_KYLIN_MS}"
        KYLIN_UOS_FAMILY="rhel8-line"
        KYLIN_UOS_GLIBC="28"
    fi
fi

# ---- 2. 统信 UOS ----
if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    _OS_ID_LOWER="$(printf '%s' "${ID:-}" | tr '[:upper:]' '[:lower:]')"
    _OS_NAME_LOWER="$(printf '%s' "${NAME:-}" | tr '[:upper:]' '[:lower:]')"
    if [[ "${_OS_ID_LOWER}" == "uos" || "${_OS_ID_LOWER}" == "uniontech" || "${_OS_NAME_LOWER}" == *"uos"* || "${_OS_NAME_LOWER}" == *"uniontech"* ]]; then
        # UOS 版本：例如 1050 / 1060 / 1070 / 20 / 1050e / 1070e
        _UOS_VER="${VERSION_ID:-${VERSION:-unknown}}"
        # 区分桌面 vs 服务器
        # UOS 惯例的版本标识文件是 /etc/os-version（部分版本在 /usr/lib/os-version），
        # 不能只看 /usr/lib/os-version，否则 UOS Server 25 等会被误判为 desktop（2026-11-14 实测）
        _UOS_OSV_FILE=""
        [[ -f /etc/os-version ]] && _UOS_OSV_FILE="/etc/os-version"
        [[ -z "${_UOS_OSV_FILE}" && -f /usr/lib/os-version ]] && _UOS_OSV_FILE="/usr/lib/os-version"
        if [[ -n "${_UOS_OSV_FILE}" ]] && grep -qi 'server' "${_UOS_OSV_FILE}" 2>/dev/null; then
            KYLIN_UOS_VARIANT="server"
        elif [[ "${_UOS_VER}" == *"e" ]]; then
            KYLIN_UOS_VARIANT="server"
        elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
            # 兜底：有 dnf/yum 的 UOS 必是 rpm 系服务器版（桌面版是 dpkg/apt）
            KYLIN_UOS_VARIANT="server"
        else
            KYLIN_UOS_VARIANT="desktop"
        fi
        KYLIN_UOS_OS="uos-${KYLIN_UOS_VARIANT}-${_UOS_VER}"
        # 服务器版用 RPM（apt-rpm），桌面版用 dpkg
        if [[ "${KYLIN_UOS_VARIANT}" == "server" ]]; then
            # 进一步细分：1050e/1060e 是 RHEL8 衍生；1070e 是 RHEL9/openeuler 衍生；
            # UOS Server 23/24/25 基于 openEuler（25 = openEuler 24.03 基座，glibc 2.38）
            case "${_UOS_VER}" in
                1050*|1060*)               KYLIN_UOS_FAMILY="rhel8-line"; KYLIN_UOS_GLIBC="28" ;;
                1070*|20*|21*|22*|23*|24*|25*)   KYLIN_UOS_FAMILY="openeuler-line"; KYLIN_UOS_GLIBC="28" ;;
                *)                         KYLIN_UOS_FAMILY="rhel8-line"; KYLIN_UOS_GLIBC="28" ;;
            esac
        else
            KYLIN_UOS_FAMILY="deb-line"
            KYLIN_UOS_GLIBC="28"
        fi
    fi
fi

# 防止空值
if [[ -n "${KYLIN_UOS_OS}" ]]; then
    KYLIN_UOS_KERNEL="$(uname -r 2>/dev/null)"
    export KYLIN_UOS_OS KYLIN_UOS_VARIANT KYLIN_UOS_FAMILY KYLIN_UOS_GLIBC KYLIN_UOS_KERNEL KYLIN_UOS_CODENAME KYLIN_UOS_MILESTONE
fi
return 0 2>/dev/null || exit 0