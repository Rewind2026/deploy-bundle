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
    # Adoptium/temurin 命名用 x64/aarch64，与 uname -m (x86_64) 不同，两种都要匹配
    local jdk_arch="${ARCH_VAL}"
    [[ "${ARCH_VAL}" == "x86_64" ]] && jdk_arch="x64"
    local patterns=(
        "OpenJDK8U-jdk_${jdk_arch}_linux_hotspot"
        "temurin-8-jdk_${jdk_arch}"
        "OpenJDK8U"
        "temurin-8"
        "jdk-8u"
        "jdk8u"
        "jdk-8-"
        "jdk8-"
        "bisheng-jdk-8"
    )

    local pkgs_dir="${PKG_DIR}/${FAMILY}/${ARCH_VAL}"
    [[ -d "${pkgs_dir}" ]] || { diag_pkgs_dir "${FAMILY}" "${ARCH_VAL}" "${PKG_DIR}"; die "${EX_DEPS}" "包目录不存在：${pkgs_dir}"; }

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
    info "注入 JDK 8 兼容补丁（增量修改，不覆盖文件）：${SEC_FILE}"
    if is_dry_run; then
        echo "[DRY-RUN] sed ${SEC_FILE}（tls/certpath disabledAlgorithms、legacyAlgorithms、DNS 缓存、熵源）"
    else
        cp -a "${SEC_FILE}" "${SEC_FILE}.orig.$(date +%Y%m%d%H%M%S)" || true
        # 覆盖式替换会丢掉整个 security.provider.N 注册列表，
        # 导致 SHA-256 等 MessageDigest 不可用（MySQL Connector/J caching_sha2 认证直接报错）。
        # 因此只对目标属性做增量修改，不动文件其余内容。
        sed -i \
            -e 's|^jdk.tls.disabledAlgorithms=.*|jdk.tls.disabledAlgorithms=SSLv3, TLSv1, TLSv1.1, RC4, DES, MD5withRSA, DH keySize < 1024, EC keySize < 224|' \
            -e 's|^jdk.certpath.disabledAlgorithms=.*|jdk.certpath.disabledAlgorithms=MD2, MD5, RSA keySize < 1024, EC keySize < 224|' \
            -e 's|^jdk.tls.legacyAlgorithms=.*|jdk.tls.legacyAlgorithms=3DES_EDE_CBC, TLS_RSA_WITH_AES_128_CBC_SHA, TLS_RSA_WITH_AES_256_CBC_SHA, TLS_RSA_WITH_AES_128_CBC_SHA256, TLS_RSA_WITH_AES_256_CBC_SHA256|' \
            -e 's|^networkaddress.cache.ttl=.*|networkaddress.cache.ttl=-1|' \
            -e 's|^networkaddress.cache.negative.ttl=.*|networkaddress.cache.negative.ttl=-1|' \
            -e 's|^securerandom.source=.*|securerandom.source=file:/dev/./urandom|' \
            "${SEC_FILE}"
        # 属性在原文件中被注释或不存在时补一行
        grep -q '^jdk.tls.legacyAlgorithms=' "${SEC_FILE}" \
            || echo 'jdk.tls.legacyAlgorithms=3DES_EDE_CBC, TLS_RSA_WITH_AES_128_CBC_SHA, TLS_RSA_WITH_AES_256_CBC_SHA, TLS_RSA_WITH_AES_128_CBC_SHA256, TLS_RSA_WITH_AES_256_CBC_SHA256' >> "${SEC_FILE}"
        grep -q '^networkaddress.cache.ttl=' "${SEC_FILE}" \
            || echo 'networkaddress.cache.ttl=-1' >> "${SEC_FILE}"
        grep -q '^networkaddress.cache.negative.ttl=' "${SEC_FILE}" \
            || echo 'networkaddress.cache.negative.ttl=-1' >> "${SEC_FILE}"
        ok "已注入补丁（增量）：${SEC_FILE}"
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