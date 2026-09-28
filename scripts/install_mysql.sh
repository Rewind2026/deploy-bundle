#!/usr/bin/env bash
# install_mysql.sh - MySQL 8 离线部署

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

stage_begin "install_mysql"
require_detect
require_root

FAMILY="$(os_family)"
ARCH_VAL="$(arch)"
PKG_MGR_VAL="$(pkg_mgr)"

local_deps_install() {
    local depname="$1"
    local pkgs_dir="${PKG_DIR}/${FAMILY}/${ARCH_VAL}"
    local sub
    case "${PKG_MGR_VAL}" in
        rpm) sub="rpms" ;;
        dpkg) sub="debs" ;;
        *) die "${EX_SYS}" "未知包管理器：${PKG_MGR_VAL}" ;;
    esac

    local found
    found="$(find "${pkgs_dir}/${sub}" -maxdepth 1 -type f \
        \( -name "${depname}*.rpm" -o -name "${depname}*.deb" \) 2>/dev/null | head -n3 || true)"

    if [[ -z "${found}" ]]; then
        warn "本地未找到 ${depname}，尝试系统包管理器"
        case "${PKG_MGR_VAL}" in
            rpm)
                if have_cmd dnf; then
                    run dnf -y install "${depname}" 2>&1 | tee -a "${LOG_FILE}" || warn "系统未安装 ${depname}（继续）"
                elif have_cmd yum; then
                    run yum -y install "${depname}" 2>&1 | tee -a "${LOG_FILE}" || warn "系统未安装 ${depname}（继续）"
                fi
                ;;
            dpkg)
                run apt-get -y install "${depname}" 2>&1 | tee -a "${LOG_FILE}" || warn "系统未安装 ${depname}（继续）"
                ;;
        esac
        return 0
    fi

    info "安装本地依赖：$(basename "${found}" | head -n1)"
    case "${PKG_MGR_VAL}" in
        rpm) run rpm -Uvh --nodeps "${found}" 2>&1 | tee -a "${LOG_FILE}" || true ;;
        dpkg) run dpkg -i "${found}" 2>&1 | tee -a "${LOG_FILE}" || run apt-get -y -f install ;;
    esac
}

for dep in libaio numactl-libs ncurses-compat-libs; do
    local_deps_install "${dep}"
done

select_mysql_tar() {
    local pkgs_dir="${PKG_DIR}/${FAMILY}/${ARCH_VAL}"
    [[ -d "${pkgs_dir}" ]] || die "${EX_DEPS}" "包目录不存在：${pkgs_dir}"

    local host_glibc_minor="28"
    if command -v ldd >/dev/null 2>&1; then
        local host_glibc_full
        host_glibc_full="$(ldd --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1 || true)"
        case "${host_glibc_full}" in
            2.17|2.18|2.19|2.20|2.21|2.22|2.23|2.24|2.25|2.26|2.27) host_glibc_minor="17" ;;
            *)                   host_glibc_minor="28" ;;
        esac
    fi
    info "本机 glibc 版本提示：${host_glibc_minor} 系列（实际以 ${host_glibc_full:-未知} 为准）"

    local patterns=(
        "mysql-8.*-linux-glibc${host_glibc_minor}-${ARCH_VAL}"
        "mysql-8.*-linux-glibc2.28-${ARCH_VAL}"
        "mysql-8.*-linux-glibc2.17-${ARCH_VAL}"
        "mysql-8.*-${ARCH_VAL}"
        "mysql-8."
    )
    for pat in "${patterns[@]}"; do
        local found
        found="$(find "${pkgs_dir}" -maxdepth 2 -type f -name "${pat}*.tar.xz" 2>/dev/null | head -n1 || true)"
        [[ -n "${found}" && -f "${found}" ]] && { echo "${found}"; return 0; }
    done

    find "${pkgs_dir}/rpms" -maxdepth 1 -name "mysql-community-server-*.rpm" 2>/dev/null | head -n1
    find "${pkgs_dir}/debs" -maxdepth 1 -name "mysql-server_*.deb" 2>/dev/null | head -n1
}

MYSQL_PKG="$(select_mysql_tar || true)"
if [[ -z "${MYSQL_PKG}" || ! -e "${MYSQL_PKG}" ]]; then
    die "${EX_DEPS}" "未在 packages/${FAMILY}/${ARCH_VAL}/ 找到 MySQL 包"
fi
info "选中 MySQL 包：${MYSQL_PKG}"

if [[ -e "${TARGET_MYSQL_DIR}" && ! -L "${TARGET_MYSQL_DIR}" ]]; then
    BACKUP_DIR="$(ensure_backup_dir mysql_existing)"
    warn "备份现有 ${TARGET_MYSQL_DIR} → ${BACKUP_DIR}/mysql"
    if ! is_dry_run; then
        cp -a "${TARGET_MYSQL_DIR}" "${BACKUP_DIR}/mysql" || die "${EX_SYS}" "备份失败"
    fi
fi

case "${MYSQL_PKG}" in
    *.tar.xz|*.tar.gz)
        if [[ -L "${TARGET_MYSQL_DIR}" ]]; then run rm -f "${TARGET_MYSQL_DIR}"; fi
        mkdir -p "${TARGET_MYSQL_DIR}"
        info "解压 ${MYSQL_PKG} -> ${TARGET_MYSQL_DIR}"
        run tar -xf "${MYSQL_PKG}" -C "${TARGET_MYSQL_DIR}" --strip-components=1
        MYSQL_BIN="${TARGET_MYSQL_DIR}/bin/mysqld"
        ;;
    *.rpm)
        info "安装 RPM：${MYSQL_PKG}"
        rpm_install_local "${FAMILY}" "${ARCH_VAL}"
        TARGET_MYSQL_DIR="/opt/mysql"
        if [[ ! -e "${TARGET_MYSQL_DIR}" ]]; then
            mkdir -p "${TARGET_MYSQL_DIR}"
            if [[ -d /var/lib/mysql ]]; then
                ln -sfn /var/lib/mysql "${TARGET_MYSQL_DIR}/data" 2>/dev/null || true
            fi
        fi
        MYSQL_BIN="/usr/sbin/mysqld"
        ;;
    *.deb)
        info "安装 DEB：${MYSQL_PKG}"
        deb_install_local "${FAMILY}" "${ARCH_VAL}"
        TARGET_MYSQL_DIR="/opt/mysql"
        if [[ ! -e "${TARGET_MYSQL_DIR}" ]]; then
            mkdir -p "${TARGET_MYSQL_DIR}"
            if [[ -d /var/lib/mysql ]]; then
                ln -sfn /var/lib/mysql "${TARGET_MYSQL_DIR}/data" 2>/dev/null || true
            fi
        fi
        MYSQL_BIN="/usr/sbin/mysqld"
        ;;
    *) die "${EX_DEPS}" "无法识别 MySQL 包格式：${MYSQL_PKG}" ;;
esac

info "确保 mysql 用户/组存在"
if ! getent group mysql >/dev/null 2>&1; then
    if is_dry_run; then echo "[DRY-RUN] groupadd -r mysql"
    else groupadd -r mysql || die "${EX_SYS}" "groupadd mysql 失败"; fi
fi
if ! getent passwd mysql >/dev/null 2>&1; then
    if is_dry_run; then echo "[DRY-RUN] useradd -r -g mysql -d /var/lib/mysql -s /sbin/nologin mysql"
    else useradd -r -g mysql -d /var/lib/mysql -s /sbin/nologin mysql \
        || die "${EX_SYS}" "useradd mysql 失败"; fi
fi

if [[ -d "${TARGET_DATA_DIR}" && -n "$(ls -A "${TARGET_DATA_DIR}" 2>/dev/null)" ]]; then
    warn "${TARGET_DATA_DIR} 已存在数据，保留并复用"
    REINIT=0
else
    REINIT=1
    info "初始化数据目录：${TARGET_DATA_DIR}"
    if is_dry_run; then
        echo "[DRY-RUN] mkdir -p ${TARGET_DATA_DIR}"
    else
        if findmnt "${TARGET_DATA_DIR}" >/dev/null 2>&1; then
            warn "TARGET_DATA_DIR 是独立挂载点，拒绝 rm"
            REINIT=0
        elif [[ -L "${TARGET_DATA_DIR}" ]]; then
            local target; target="$(readlink -f "${TARGET_DATA_DIR}")"
            warn "${TARGET_DATA_DIR} 是 symlink -> ${target}，拒绝 rm"
            REINIT=0
        else
            run rm -rf "${TARGET_DATA_DIR}"
            mkdir -p "${TARGET_DATA_DIR}"
            chown mysql:mysql "${TARGET_DATA_DIR}"
            chmod 750 "${TARGET_DATA_DIR}"
        fi
    fi
fi

if [[ ! -f "${CFG_DIR}/my.cnf.template" ]]; then
    die "${EX_DEPS}" "缺少 my.cnf.template"
fi

TOTAL_MEM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 2048)"
if [[ "${TOTAL_MEM_MB}" -lt 1024 ]]; then
    BUFFER_POOL="256M"
    LOG_FILE_SIZE="128M"
elif [[ "${TOTAL_MEM_MB}" -lt 4096 ]]; then
    BUFFER_POOL="$(awk -v m="${TOTAL_MEM_MB}" 'BEGIN{print int(m*0.4)"M"}')"
    LOG_FILE_SIZE="256M"
else
    BUFFER_POOL="$(awk -v m="${TOTAL_MEM_MB}" 'BEGIN{print int(m*0.5)"M"}')"
    LOG_FILE_SIZE="512M"
fi
info "InnoDB buffer_pool=${BUFFER_POOL}  log_file_size=${LOG_FILE_SIZE}"

MY_CNF="/etc/my.cnf"
info "生成 ${MY_CNF}"
if is_dry_run; then
    echo "[DRY-RUN] sed replace ${MY_CNF}"
else
    [[ -f "${MY_CNF}" ]] && cp -a "${MY_CNF}" "${MY_CNF}.orig.$(date +%Y%m%d%H%M%S)" || true
    sed -e "s|__MYSQL_PORT__|${MYSQL_PORT}|g" \
        -e "s|__MYSQL_HOME__|${TARGET_MYSQL_DIR}|g" \
        -e "s|__MYSQL_DATA_DIR__|${TARGET_DATA_DIR}|g" \
        -e "s|__INNODB_BUFFER_POOL_SIZE__|${BUFFER_POOL}|g" \
        -e "s|__INNODB_LOG_FILE_SIZE__|${LOG_FILE_SIZE}|g" \
        "${CFG_DIR}/my.cnf.template" > "${MY_CNF}"
    chmod 644 "${MY_CNF}"
fi

if [[ "${REINIT}" -eq 1 ]]; then
    info "执行 mysqld --initialize-insecure"
    if is_dry_run; then
        echo "[DRY-RUN] mysqld --initialize-insecure"
    else
        run "${MYSQL_BIN}" \
            --initialize-insecure \
            --user=mysql \
            --basedir="${TARGET_MYSQL_DIR}" \
            --datadir="${TARGET_DATA_DIR}" \
            --default-time-zone='+08:00' \
            2>&1 | tee -a "${LOG_FILE}" \
            || die "${EX_SYS}" "mysqld --initialize 失败"
        ok "数据目录初始化完成"
    fi

    info "启动临时实例（无密码）"
    sock="/tmp/mysql_init.sock"
    init_log="/tmp/mysql_init.log"
    if ! is_dry_run; then
        "${MYSQL_BIN}" \
            --no-defaults \
            --socket="${sock}" \
            --port=0 \
            --skip-networking \
            --skip-grant-tables \
            --user=mysql \
            --basedir="${TARGET_MYSQL_DIR}" \
            --datadir="${TARGET_DATA_DIR}" \
            > "${init_log}" 2>&1 &
        mysqld_pid=$!

        cleanup_init() {
            if [[ -n "${mysqld_pid:-}" ]] && kill -0 "${mysqld_pid}" 2>/dev/null; then
                kill "${mysqld_pid}" 2>/dev/null || true
                sleep 1
                kill -9 "${mysqld_pid}" 2>/dev/null || true
            fi
            rm -f "${sock}" "${init_log}"
        }
        trap cleanup_init EXIT ERR INT TERM

        i=0
        while [[ ! -S "${sock}" && ${i} -lt 30 ]]; do
            sleep 1
            i=$((i+1))
        done

        if [[ ! -S "${sock}" ]]; then
            die "${EX_SYS}" "临时 mysqld 未启动，请查看 ${init_log}"
        fi

        MYSQL_CLI="${TARGET_MYSQL_DIR}/bin/mysql"
        [[ -x "${MYSQL_CLI}" ]] || MYSQL_CLI="$(command -v mysql || true)"
        if [[ -z "${MYSQL_CLI}" ]]; then
            die "${EX_DEPS}" "未找到 mysql 客户端"
        fi

        ROOT_PW=""
        ADMIN_PW=""
        ROOT_PW="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20 || true)"
        ADMIN_PW="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20 || true)"
        [[ -z "${ROOT_PW}" ]] && ROOT_PW="$(openssl rand -hex 12)"
        [[ -z "${ADMIN_PW}" ]] && ADMIN_PW="$(openssl rand -hex 12)"

        "${MYSQL_CLI}" --socket="${sock}" --protocol=socket <<SQL
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '${ROOT_PW}';
CREATE USER IF NOT EXISTS 'admin'@'localhost' IDENTIFIED WITH mysql_native_password BY '${ADMIN_PW}';
GRANT ALL PRIVILEGES ON *.* TO 'admin'@'localhost' WITH GRANT OPTION;
CREATE USER IF NOT EXISTS 'admin'@'127.0.0.1' IDENTIFIED WITH mysql_native_password BY '${ADMIN_PW}';
GRANT ALL PRIVILEGES ON *.* TO 'admin'@'127.0.0.1' WITH GRANT OPTION;
CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED WITH caching_sha2_password BY '${ROOT_PW}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

        umask 077
        printf 'root@localhost (caching_sha2): %s\nroot@127.0.0.1 (caching_sha2): %s\nadmin@localhost (mysql_native_password): %s\nadmin@127.0.0.1 (mysql_native_password): %s\n' \
            "${ROOT_PW}" "${ROOT_PW}" "${ADMIN_PW}" "${ADMIN_PW}" \
            > "${TARGET_DATA_DIR}/.root_password"
        chmod 600 "${TARGET_DATA_DIR}/.root_password"
        chown mysql:mysql "${TARGET_DATA_DIR}/.root_password"

        "${MYSQL_CLI}" --socket="${sock}" --protocol=socket -e "SHUTDOWN;"
        trap - EXIT ERR INT TERM
        i=0
        while kill -0 "${mysqld_pid}" 2>/dev/null && [[ ${i} -lt 10 ]]; do
            sleep 1; i=$((i+1))
        done
        rm -f "${sock}" "${init_log}"

        ok "MySQL 初始化完成"
        ok "密码已记录到：${TARGET_DATA_DIR}/.root_password（mysql:mysql 0600）"
    fi
fi

if [[ -x "${TARGET_MYSQL_DIR}/bin/mysql" ]]; then
    if ! is_dry_run; then
        ln -sf "${TARGET_MYSQL_DIR}/bin/mysql" /usr/local/bin/mysql 2>/dev/null || true
        ln -sf "${TARGET_MYSQL_DIR}/bin/mysqldump" /usr/local/bin/mysqldump 2>/dev/null || true
    fi
fi

if ! is_dry_run; then
    local tmp_env; tmp_env="$(mktemp /tmp/deploy-bundle.env.XXXXXX)"
    grep -v -E '^(MYSQL_HOME|MYSQL_BIN|MYSQL_CNF)=' /opt/deploy-bundle.env > "${tmp_env}" 2>/dev/null || true
    cat >> "${tmp_env}" <<EOF
MYSQL_HOME=${TARGET_MYSQL_DIR}
MYSQL_BIN=${MYSQL_BIN}
MYSQL_CNF=${MY_CNF}
EOF
    mv "${tmp_env}" /opt/deploy-bundle.env
fi

ok "MySQL 安装完成：${TARGET_MYSQL_DIR}"
ok "数据目录：${TARGET_DATA_DIR}"
ok "下一步：systemd_register.sh 注册服务 -> healthcheck.sh 验证"

stage_end "install_mysql"
exit "${EX_OK}"