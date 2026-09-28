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
fi

if [[ -n "${KYLIN_UOS_MILESTONE}" ]]; then
    _KYLIN_MS="${KYLIN_UOS_MILESTONE}"
    _KYLIN_SP=""
    _KYLIN_MS_TAIL=""
    _KYLIN_V11_MINOR=""

    if [[ "${_KYLIN_MS}" =~ V11-([0-9]+) ]]; then
        _KYLIN_V11_MINOR="${BASH_REMATCH[1]}"
    fi
    if [[ "${_KYLIN_MS}" =~ V10-?SP([0-9]+) ]]; then
        _KYLIN_SP="${BASH_REMATCH[1]}"
    fi
    if [[ "${_KYLIN_MS}" =~ Release-([0-9]+) ]]; then
        _KYLIN_MS_TAIL="${BASH_REMATCH[1]}"
    fi

    if [[ "${_KYLIN_MS}" == *"V11"* ]]; then
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
        if [[ -f /usr/lib/os-version ]] && grep -qi 'server' /usr/lib/os-version 2>/dev/null; then
            KYLIN_UOS_VARIANT="server"
        elif [[ "${_UOS_VER}" == *"e" ]]; then
            KYLIN_UOS_VARIANT="server"
        else
            KYLIN_UOS_VARIANT="desktop"
        fi
        KYLIN_UOS_OS="uos-${KYLIN_UOS_VARIANT}-${_UOS_VER}"
        # 服务器版用 RPM（apt-rpm），桌面版用 dpkg
        if [[ "${KYLIN_UOS_VARIANT}" == "server" ]]; then
            # 进一步细分：1050e 是 RHEL8 衍生；1070e 是 RHEL9 衍生（openeuler-line）
            case "${_UOS_VER}" in
                1050*|1060*)         KYLIN_UOS_FAMILY="rhel8-line"; KYLIN_UOS_GLIBC="28" ;;
                1070*|20*|21*|22*)   KYLIN_UOS_FAMILY="openeuler-line"; KYLIN_UOS_GLIBC="28" ;;
                *)                   KYLIN_UOS_FAMILY="rhel8-line"; KYLIN_UOS_GLIBC="28" ;;
            esac
        else
            KYLIN_UOS_FAMILY="deb-line"
            KYLIN_UOS_GLIBC="14"
        fi
    fi
fi

# 防止空值
if [[ -n "${KYLIN_UOS_OS}" ]]; then
    KYLIN_UOS_KERNEL="$(uname -r 2>/dev/null)"
    export KYLIN_UOS_OS KYLIN_UOS_VARIANT KYLIN_UOS_FAMILY KYLIN_UOS_GLIBC KYLIN_UOS_KERNEL KYLIN_UOS_CODENAME KYLIN_UOS_MILESTONE
fi
return 0 2>/dev/null || exit 0