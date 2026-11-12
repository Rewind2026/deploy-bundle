#!/usr/bin/env bash
# license_collect.sh - 收集离线 deb 包 LICENSE 文本

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

FAMILY="${TARGET_FAMILY:-deb-line}"
ARCH_VAL="${TARGET_ARCH:-x86_64}"
DEBS_DIR="${PKG_DIR}/${FAMILY}/${ARCH_VAL}/debs"
OUT_DIR="/opt/deploy-bundle/LICENSES/${FAMILY}/${ARCH_VAL}"

mkdir -p "${OUT_DIR}"
TMP_SUMMARY="$(mktemp)"
for deb in "${DEBS_DIR}"/*.deb; do
    [[ -f "${deb}" ]] || continue
    name="$(basename "${deb}")"
    TMP_INFO="$(mktemp -d)"
    dpkg-deb -I "${deb}" "${TMP_INFO}/control" 2>/dev/null || true
    pkg="$(grep '^Package:' "${TMP_INFO}/control" 2>/dev/null | awk '{print $2}')"
    ver="$(grep '^Version:' "${TMP_INFO}/control" 2>/dev/null | awk '{print $2}')"
    rm -rf "${TMP_INFO}"
    out="${OUT_DIR}/${pkg:-${name}}-${ver:-unknown}-LICENSE.txt"
    {
        echo "Package: ${pkg:-${name}}"
        echo "Version: ${ver:-unknown}"
        echo "Source:   ${deb}"
        echo "Copyright fields:"
        dpkg-deb -f "${deb}" Copyright License 2>/dev/null || echo "(none)"
        echo
        echo "==== upstream copyright/notice (best-effort) ===="
        dpkg-deb -e "${deb}" "${TMP_INFO:-/tmp}" 2>/dev/null || true
    } > "${out}"
    printf '%s\t%s\t%s\n' "${name}" "${pkg:-?}" "${ver:-?}" >> "${TMP_SUMMARY}"
done
mv "${TMP_SUMMARY}" "${OUT_DIR}/_summary.tsv"
ok "许可证已收集到：${OUT_DIR}/"