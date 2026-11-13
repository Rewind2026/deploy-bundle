#!/usr/bin/env bash
# collect_mysql.sh - 采集 MySQL 8.4 LTS tar.xz（硬性要求 8.4.x）
# 架构支持：x86_64（glibc2.17 + glibc2.28 双变体）/ aarch64（仅 glibc2.28 官方构建）
# loongarch64 已移除支持

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

FAMILY="${TARGET_FAMILY:-$(auto_detect_family)}"
ARCH_VAL="${TARGET_ARCH:-$(auto_detect_arch)}"

# 架构白名单
case "${ARCH_VAL}" in
    x86_64|aarch64) : ;;
    *) die "${EX_USAGE}" "仅支持 x86_64 / aarch64，当前架构：${ARCH_VAL}" ;;
esac

OUT_DIR="${PKG_DIR}/${FAMILY}/${ARCH_VAL}/mysql"
mkdir -p "${OUT_DIR}"

# 版本硬性要求：MySQL 8.4.x（可用环境变量 MYSQL_VERSION 覆盖小版本，仍必须在 8.4 系列内）
MYSQL_VERSION="${MYSQL_VERSION:-8.4.6}"
case "${MYSQL_VERSION}" in
    8.4.*) : ;;
    *) die "${EX_USAGE}" "MySQL 版本硬性要求 8.4.x，当前配置：${MYSQL_VERSION}" ;;
esac

# 双重校验：文件名 + tarball 顶层目录都必须是 mysql-8.4.*
check_mysql_tarball() {
    local f="$1"
    local base; base="$(basename "${f}")"
    case "${base}" in
        mysql-8.4.*) : ;;
        *) err "MySQL 硬性要求 8.4.x，拒绝收录：${base}"; return 1 ;;
    esac
    # 全量完整性校验：xz -t 会解压校验整个流，残卷/断点续传未完成的包必失败
    if ! xz -t "${f}" 2>/dev/null; then
        err "tarball 不完整（xz 校验失败，可能是断点续传残卷）：${base}"
        return 1
    fi
    local top
    top="$(tar -tf "${f}" 2>/dev/null | head -n1 || true)"
    case "${top}" in
        mysql-8.4.*) : ;;
        *) err "tarball 内容与 8.4.x 不符（顶层目录：${top:-无法识别}），拒绝收录：${base}"; return 1 ;;
    esac
    return 0
}

# 本地优先（仍须满足 8.4.x，不符合则直接报错退出，不静默收录）
for cand in "${HOME}/mysql"*.tar.xz /opt/mysql*.tar.xz /usr/local/mysql*.tar.xz; do
    if [[ -f "${cand}" ]]; then
        if check_mysql_tarball "${cand}"; then
            cp -n "${cand}" "${OUT_DIR}/"
            info "已复制本地 MySQL: ${cand}"
            exit 0
        else
            die "${EX_USAGE}" "本地 MySQL 包不符合 8.4.x 硬性要求，请替换为 mysql-8.4.x tarball 后重试"
        fi
    fi
done

# 下载指定 glibc 变体（直存 OUT_DIR，支持跨运行断点续传）
download_variant() {
    local tag="$1"
    local fname="mysql-${MYSQL_VERSION}-linux-${tag}-${ARCH_VAL}.tar.xz"
    local out_file="${OUT_DIR}/${fname}"
    # 已存在且通过 tar 校验的完整包才跳过（残卷会续传补齐）
    if [[ -f "${out_file}" ]] && check_mysql_tarball "${out_file}"; then
        info "已存在完整包，跳过下载：${fname}"
        return 0
    fi
    local url="https://dev.mysql.com/get/Downloads/MySQL-8.4/${fname}"
    info "下载：${fname}（断点续传，最多 3 轮重试）"
    local dl_ok=0
    local _try
    for _try in 1 2 3; do
        _ec=0
        curl -fsSL --retry 2 --retry-delay 3 -C - "${url}" -o "${out_file}" && _ec=0 || _ec=$?
        if [[ ${_ec} -eq 0 ]] && check_mysql_tarball "${out_file}"; then
            dl_ok=1
            break
        fi
        # 退出码 22 = HTTP 错误（如 404）：dev.mysql.com 只保留 8.4 系列较新的补丁版，
        # 旧补丁版会挪到 downloads.mysql.com/archives，重试必然还是 404，立即终止
        if [[ ${_ec} -eq 22 ]]; then
            warn "${url} 返回 HTTP 错误（该地址无此版本，属永久性 404），跳过重试"
            break
        fi
        warn "下载中断（第 ${_try}/3 轮）：${fname}，断点续传重试中..."
        sleep 3
    done
    if [[ "${dl_ok}" -eq 1 ]]; then
        ok "已就绪：${out_file}"
        return 0
    fi
    warn "下载失败：${fname}（可人工放到 ${OUT_DIR}/ 后重跑）"
    return 1
}

case "${ARCH_VAL}" in
    x86_64)
        # 官方同时发布 glibc2.17 / glibc2.28 构建，双变体都采：
        # 客户机 glibc 2.17（CentOS7/麒麟 V10 SP1 等）与 >=2.28（el8 系/openEuler 等）都能覆盖
        download_variant "glibc2.17" || true
        download_variant "glibc2.28" || true
        ;;
    aarch64)
        # 官方仅发布 glibc2.28 构建；aarch64 + glibc2.17 客户机（麒麟 V10 SP1 鲲鹏等）不支持，
        # install_mysql.sh 会在部署时明确拒绝
        download_variant "glibc2.28" || true
        ;;
esac

# 校验最终产物：至少一个 8.4.x tarball
if ! ls "${OUT_DIR}"/mysql-8.4.*.tar.xz >/dev/null 2>&1; then
    die "${EX_DEPS}" "未采集到任何 MySQL 8.4.x tarball，请检查网络或人工放置到 ${OUT_DIR}/"
fi
ok "MySQL 采集完成：${OUT_DIR}/"
exit 0