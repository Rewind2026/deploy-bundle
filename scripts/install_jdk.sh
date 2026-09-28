#!/usr/bin/env bash
# install_jdk.sh - JDK 8 离线部署

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

stage_begin "install_jdk"
require_detect
require_root

FAMILY="$(os_family)"
ARCH_VAL="$(arch)"

select_jdk_tar() {
    local patterns=(
        "OpenJDK8U-jdk_${ARCH_VAL}_linux_hotspot"
        "temurin-8-jdk_${ARCH_VAL}"
        "jdk-8u"
        "jdk8u"
        "jdk-8-"
        "jdk8-"
        "bisheng-jdk-8"
        "jdk8-loongarch"
    )

    local pkgs_dir="${PKG_DIR}/${FAMILY}/${ARCH_VAL}"
    [[ -d "${pkgs_dir}" ]] || die "${EX_DEPS}" "包目录不存在：${pkgs_dir}"

    for pat in "${patterns[@]}"; do
        local found
        found="$(find "${pkgs_dir}" -maxdepth 2 -type f \
            \( -name "${pat}*.tar.gz" -o -name "${pat}*.tgz" \) 2>/dev/null | head -n1 || true)"
        if [[ -n "${found}" && -f "${found}" ]]; then
            echo "${found}"
            return 0
        fi
    done

    find "${pkgs_dir}" -maxdepth 2 -type f \
        \( -name "*jdk*8*.tar.gz" -o -name "*jdk*8*.tgz" \) 2>/dev/null | head -n1
}

JDK_TAR="$(select_jdk_tar || true)"
if [[ -z "${JDK_TAR}" || ! -f "${JDK_TAR}" ]]; then
    die "${EX_DEPS}" "未在 packages/${FAMILY}/${ARCH_VAL}/ 找到 JDK 8 tar 包"
fi
info "选中 JDK 包：${JDK_TAR}"

if [[ -e "${TARGET_JDK_DIR}" && ! -L "${TARGET_JDK_DIR}" ]]; then
    BACKUP_DIR="$(ensure_backup_dir jdk_existing)"
    warn "${TARGET_JDK_DIR} 已存在，备份至 ${BACKUP_DIR}/jdk"
    if is_dry_run; then
        echo "[DRY-RUN] cp -a ${TARGET_JDK_DIR} ${BACKUP_DIR}/jdk"
    else
        cp -a "${TARGET_JDK_DIR}" "${BACKUP_DIR}/jdk" || die "${EX_SYS}" "备份失败"
    fi
fi

if [[ -L "${TARGET_JDK_DIR}" ]]; then
    run rm -f "${TARGET_JDK_DIR}"
fi
mkdir -p "${TARGET_JDK_DIR}"
info "解压 ${JDK_TAR} -> ${TARGET_JDK_DIR}"
run tar -xf "${JDK_TAR}" -C "${TARGET_JDK_DIR}" --strip-components=1

if [[ ! -x "${TARGET_JDK_DIR}/bin/java" ]]; then
    die "${EX_SYS}" "JDK 解压后未找到 ${TARGET_JDK_DIR}/bin/java"
fi
JAVA_VER="$("${TARGET_JDK_DIR}/bin/java" -version 2>&1 | head -n1)"
ok "java -version -> ${JAVA_VER}"

# java.security 兼容补丁（jdk 8 / 11+ 路径自适应）
SEC_FILE=""
for cand in \
    "${TARGET_JDK_DIR}/jre/lib/security/java.security" \
    "${TARGET_JDK_DIR}/conf/security/java.security"; do
    if [[ -f "${cand}" ]]; then
        SEC_FILE="${cand}"
        break
    fi
done

if [[ -n "${SEC_FILE}" ]]; then
    info "注入 JDK 8 兼容补丁：${SEC_FILE}"
    if is_dry_run; then
        echo "[DRY-RUN] cp ${CFG_DIR}/java.security ${SEC_FILE}.new"
    else
        cp -a "${SEC_FILE}" "${SEC_FILE}.orig.$(date +%Y%m%d%H%M%S)" || true
        cp -f "${CFG_DIR}/java.security" "${SEC_FILE}"
        ok "已注入补丁（覆盖式）：${SEC_FILE}"
    fi
else
    warn "未找到 java.security，跳过补丁注入"
fi

# /etc/profile.d
PROFILE_SH="/etc/profile.d/deploy-bundle-jdk.sh"
if is_dry_run; then
    echo "[DRY-RUN] write ${PROFILE_SH}"
else
    cat > "${PROFILE_SH}" <<EOF
export JAVA_HOME=${TARGET_JDK_DIR}
export JRE_HOME=\${JAVA_HOME}/jre
export CLASSPATH=.:\${JAVA_HOME}/lib:\${JRE_HOME}/lib
export PATH=\${JAVA_HOME}/bin:\${JRE_HOME}/bin:\${PATH}
EOF
    chmod 644 "${PROFILE_SH}"
fi

# update-alternatives 含 slave
if have_cmd update-alternatives; then
    if [[ -x "${TARGET_JDK_DIR}/bin/javac" ]]; then
        update-alternatives --install /usr/bin/java java "${TARGET_JDK_DIR}/bin/java" 2000 \
            --slave /usr/bin/javac javac "${TARGET_JDK_DIR}/bin/javac" \
            --slave /usr/bin/jar   jar   "${TARGET_JDK_DIR}/bin/jar" || true
    else
        update-alternatives --install /usr/bin/java java "${TARGET_JDK_DIR}/bin/java" 2000 || true
    fi
fi

ok "JDK 安装完成：${TARGET_JDK_DIR}"
stage_end "install_jdk"
exit "${EX_OK}"