id: /root/.trae-cn-server/bin/stable-d654d294a690adb43b5bb35d5b37adf9f292cee0-debian10/modules/ai-agent/libselinux.so.1: no version information available (required by id)
#!/usr/bin/env bash
# collect_rpm_deps.sh - 在 rpm 系镜像机上真实下载 MySQL 运行依赖到 packages/<F>/<A>/rpms/
# 工具自适应：优先 dnf download --resolve（dnf-plugins-core），退化 repotrack（yum-utils）
# 注意：必须在与客户机同 family 的镜像机上运行（FAQ Q21/Q22）

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

FAMILY="${TARGET_FAMILY:-$(auto_detect_family)}"
ARCH_VAL="${TARGET_ARCH:-$(auto_detect_arch)}"

OUT_DIR="${PKG_DIR}/${FAMILY}/${ARCH_VAL}/rpms"
mkdir -p "${OUT_DIR}"

# 按 family 映射依赖包名（ncurses-compat-libs 仅 el8+/openEuler 存在）
case "${FAMILY}" in
    rhel7-line)   PKGS=(libaio numactl-libs ncurses-libs) ;;
    rhel8-line|openeuler-line) PKGS=(libaio numactl-libs ncurses-compat-libs) ;;
    deb-line)     die "${EX_USAGE}" "deb 系镜像机请运行 collect_deb_deps.sh" ;;
    *)            PKGS=(libaio numactl-libs ncurses-compat-libs) ;;
esac

info "采集目标：${FAMILY}/${ARCH_VAL} → ${OUT_DIR}"
info "依赖清单：${PKGS[*]}"

DNF_BIN="$(command -v dnf || true)"
YUM_BIN="$(command -v yum || true)"
REPOTRACK="$(command -v repotrack || true)"

dnf_download_ok() {
    [[ -n "${DNF_BIN}" ]] || return 1
    "${DNF_BIN}" download --help >/dev/null 2>&1
}

if dnf_download_ok; then
    info "使用 dnf download --resolve 采集（含未安装依赖）"
    if ! is_dry_run; then
        (cd "${OUT_DIR}" && "${DNF_BIN}" download --resolve "${PKGS[@]}") 2>&1 | tee -a "${LOG_FILE}" \
            || warn "dnf download 失败，尝试 repotrack"
    fi
fi

# dnf 失败或不可用 → repotrack 兜底
if ! ls "${OUT_DIR}"/*.rpm >/dev/null 2>&1; then
    if [[ -n "${REPOTRACK}" ]]; then
        info "使用 repotrack 采集（全依赖树）"
        if ! is_dry_run; then
            (cd "${OUT_DIR}" && "${REPOTRACK}" "${PKGS[@]}") 2>&1 | tee -a "${LOG_FILE}" \
                || warn "repotrack 失败"
        fi
    else
        warn "dnf download 与 repotrack 均不可用"
        warn "请安装 dnf-plugins-core 或 yum-utils 后重跑；或人工把 ${PKGS[*]} 的 rpm 放入 ${OUT_DIR}/"
        exit "${EX_DEPS}"
    fi
fi

if ! ls "${OUT_DIR}"/*.rpm >/dev/null 2>&1; then
    die "${EX_DEPS}" "未采集到任何 rpm，请检查镜像机网络/仓库配置，或人工放置依赖包到 ${OUT_DIR}/"
fi

RPM_COUNT="$(ls "${OUT_DIR}"/*.rpm | wc -l)"
ok "rpm 依赖采集完成：${RPM_COUNT} 个包 → ${OUT_DIR}/"
info "提示：镜像机仓库与客户机基础环境可能存在版本差异，交付前务必跑 docs/VALIDATION.md 矩阵验证"
exit "${EX_OK}"
