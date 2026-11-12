#!/usr/bin/env bash
# collect_deb_deps.sh - 在 deb 系镜像机上真实下载 MySQL 运行依赖到 packages/<F>/<A>/debs/
# 机制：apt-get install --reinstall --print-uris 解析递归依赖 → 下载全部 .deb
# 注意：必须在与客户机同 family 的 deb 系镜像机上运行（FAQ Q21/Q22）

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

FAMILY="${TARGET_FAMILY:-$(auto_detect_family)}"
ARCH_VAL="${TARGET_ARCH:-$(auto_detect_arch)}"

OUT_DIR="${PKG_DIR}/${FAMILY}/${ARCH_VAL}/debs"
mkdir -p "${OUT_DIR}"

if ! command -v apt-get >/dev/null 2>&1; then
    die "${EX_USAGE}" "当前镜像机无 apt-get；deb 系依赖必须在 deb 系镜像机上采集"
fi

# 候选包名（覆盖 Ubuntu 18.04~24.04 / Debian 10~12 的命名差异：
# 24.04 的 t64 过渡改名 libaio1t64；老版本 libncurses5/libtinfo5）
CANDIDATES=(
    libaio1 libaio1t64
    libnuma1
    libncurses6 libncurses5
    libtinfo6 libtinfo5
    libgcc-s1 libgcc1
    libstdc++6
)

info "解析可用包名（在当前镜像机仓库中探测）"
EXIST=()
for p in "${CANDIDATES[@]}"; do
    if apt-cache show "${p}" >/dev/null 2>&1; then
        EXIST+=("${p}")
        info "  可用：${p}"
    fi
done

if [[ ${#EXIST[@]} -eq 0 ]]; then
    warn "仓库中未命中任何候选包，请先 apt-get update 后重跑；"
    warn "或人工把 MySQL 运行依赖（libaio/libnuma/ncurses 等）的 .deb 放入 ${OUT_DIR}/"
    exit "${EX_DEPS}"
fi

info "解析依赖 URI：${EXIST[*]}"
URIS_RAW="$(apt-get install --reinstall --print-uris -y "${EXIST[@]}" 2>/dev/null || true)"

# 提取 '.../*.deb' 形式的 URI（print-uris 输出：'http://...pkg.deb' ...)
mapfile -t URIS < <(printf '%s\n' "${URIS_RAW}" | grep -oE "'[^']+\.deb'" | tr -d "'" | sort -u)

if [[ ${#URIS[@]} -eq 0 ]]; then
    warn "未解析到任何 .deb URI（apt list 可能过期），请先 apt-get update 后重跑"
    exit "${EX_DEPS}"
fi

info "下载 ${#URIS[@]} 个 .deb（含递归依赖）"
FAIL=0
for uri in "${URIS[@]}"; do
    fname="${uri##*/}"
    if [[ -f "${OUT_DIR}/${fname}" ]]; then
        info "已存在，跳过：${fname}"
        continue
    fi
    if is_dry_run; then
        echo "[DRY-RUN] wget ${uri} → ${OUT_DIR}/"
        continue
    fi
    if wget -qO "${OUT_DIR}/${fname}" "${uri}" 2>>"${LOG_FILE}"; then
        info "  已下载：${fname}"
    else
        warn "  下载失败：${uri}"
        rm -f "${OUT_DIR}/${fname}"
        FAIL=1
    fi
done

if ! ls "${OUT_DIR}"/*.deb >/dev/null 2>&1; then
    die "${EX_DEPS}" "未采集到任何 .deb，请检查镜像机网络/源配置，或人工放置依赖包到 ${OUT_DIR}/"
fi

DEB_COUNT="$(ls "${OUT_DIR}"/*.deb | wc -l)"
ok "deb 依赖采集完成：${DEB_COUNT} 个包 → ${OUT_DIR}/"
[[ "${FAIL}" -eq 1 ]] && warn "部分包下载失败，请核对上方日志"
exit "${EX_OK}"
