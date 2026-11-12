#!/usr/bin/env bash
# write_manifest.sh - 生成 packages.manifest.tsv

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

[[ -f "${DEPLOY_BUNDLE_ROOT:-/opt/deploy-bundle}/collect.env" ]] && \
    source "${DEPLOY_BUNDLE_ROOT:-/opt/deploy-bundle}/collect.env"

stage_begin "write_manifest"

FAMILY="${COLLECT_FAMILY:-unknown}"
ARCH_VAL="${COLLECT_ARCH:-unknown}"
PKG_DIR_LOCAL_VAL="${PKG_DIR_LOCAL:-${DEPLOY_BUNDLE_ROOT:-/opt/deploy-bundle}/packages/${FAMILY}/${ARCH_VAL}}"

OUT_FILE="${PKG_DIR_LOCAL_VAL}/manifest.tsv"

{
    printf 'family\tarch\tkind\tfilename\tsize\tsha256\tpath\n'
} > "${OUT_FILE}"

info "manifest -> ${OUT_FILE}"

scan_dir() {
    local kind="$1" dir="$2"
    [[ -d "${dir}" ]] || return 0
    shopt -s nullglob
    for f in "${dir}"/*; do
        [[ -f "${f}" ]] || continue
        local name size sha256 rel
        name="$(basename "${f}")"
        size="$(stat -c '%s' "${f}" 2>/dev/null || stat -f '%z' "${f}" 2>/dev/null || echo 0)"
        sha256="$(sha256sum "${f}" | awk '{print $1}')"
        rel="${f#${DEPLOY_BUNDLE_ROOT:-/opt/deploy-bundle}/}"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${FAMILY}" "${ARCH_VAL}" "${kind}" "${name}" "${size}" "${sha256}" "${rel}" \
            >> "${OUT_FILE}"
    done
    shopt -u nullglob
}

scan_dir jdk    "${PKG_DIR_LOCAL_VAL}/jdk"
scan_dir mysql  "${PKG_DIR_LOCAL_VAL}/mysql"
scan_dir tomcat "${PKG_DIR_LOCAL_VAL}/tomcat"
scan_dir rpm    "${PKG_DIR_LOCAL_VAL}/rpms"
scan_dir deb    "${PKG_DIR_LOCAL_VAL}/debs"

total="$(tail -n +2 "${OUT_FILE}" | wc -l)"
info "条目数：${total}"

echo
echo "===== manifest 前 20 行 ====="
head -n 21 "${OUT_FILE}" | column -t -s $'\t' 2>/dev/null || head -n 21 "${OUT_FILE}"
echo

ok "manifest 生成完成"
stage_end "write_manifest"
exit "${EX_OK}"