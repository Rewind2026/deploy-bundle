#!/usr/bin/env bash
# install_mysql.sh - MySQL 8.4 LTS 离线部署（硬性要求 8.4.x）

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
# 读取 installer.sh 写入的参数（MYSQL_PORT / MYSQL_ROOT_PW 等）
[[ -f /opt/deploy-bundle.env ]] && source /opt/deploy-bundle.env

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

# 依赖包名按 family / 包管理器映射（deb 系包名与 rpm 系完全不同）
case "${PKG_MGR_VAL}" in
    dpkg) DEP_LIST=(libaio libnuma1 libncurses6 libtinfo6) ;;
    *)
        case "${FAMILY}" in
            rhel7-line) DEP_LIST=(libaio numactl-libs ncurses-libs) ;;
            *)          DEP_LIST=(libaio numactl-libs ncurses-compat-libs) ;;
        esac
        ;;
esac
for dep in "${DEP_LIST[@]}"; do
    local_deps_install "${dep}"
done

select_mysql_tar() {
    local pkgs_dir="${PKG_DIR}/${FAMILY}/${ARCH_VAL}"
    [[ -d "${pkgs_dir}" ]] || { diag_pkgs_dir "${FAMILY}" "${ARCH_VAL}" "${PKG_DIR}"; die "${EX_DEPS}" "包目录不存在：${pkgs_dir}"; }

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

    # aarch64 官方仅发布 glibc2.28 构建；glibc2.17 的 aarch64 客户机（麒麟 V10 SP1 鲲鹏等）不支持
    if [[ "${ARCH_VAL}" == "aarch64" && "${host_glibc_minor}" == "17" ]]; then
        die "${EX_DEPS}" "aarch64 + glibc2.17 组合不受支持（MySQL 8.4 官方无此构建）。请改用 glibc2.28 系 OS，或人工提供兼容包"
    fi

    # 硬性要求 8.4.x：只匹配 mysql-8.4.*，8.0/9.x 等一律不选
    # 注意：官方文件名是 glibc2.17/glibc2.28，优先匹配与本机 glibc 同档位的构建
    local patterns=(
        "mysql-8.4.*-linux-glibc2.${host_glibc_minor}-${ARCH_VAL}"
        "mysql-8.4.*-linux-glibc2.28-${ARCH_VAL}"
        "mysql-8.4.*-linux-glibc2.17-${ARCH_VAL}"
        "mysql-8.4.*-${ARCH_VAL}"
        "mysql-8.4."
    )
    for pat in "${patterns[@]}"; do
        local found
        found="$(find "${pkgs_dir}" -maxdepth 2 -type f -name "${pat}*.tar.xz" 2>/dev/null | head -n1 || true)"
        [[ -n "${found}" && -f "${found}" ]] && { echo "${found}"; return 0; }
    done

    find "${pkgs_dir}/rpms" -maxdepth 1 -name "mysql-community-server-8.4.*.rpm" 2>/dev/null | head -n1
    find "${pkgs_dir}/debs" -maxdepth 1 -name "mysql-server_8.4.*.deb" 2>/dev/null | head -n1
}

MYSQL_PKG="$(select_mysql_tar || true)"
if [[ -z "${MYSQL_PKG}" || ! -e "${MYSQL_PKG}" ]]; then
    die "${EX_DEPS}" "未在 packages/${FAMILY}/${ARCH_VAL}/ 找到 MySQL 包"
fi
info "选中 MySQL 包：${MYSQL_PKG}"

# 硬性版本守卫：MySQL 必须 8.4.x
case "$(basename "${MYSQL_PKG}")" in
    mysql-8.4.*|mysql-community-server-8.4.*|mysql-server_8.4.*) : ;;
    *) die "${EX_DEPS}" "MySQL 硬性要求 8.4.x，实际选中：$(basename "${MYSQL_PKG}")，拒绝安装" ;;
esac

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

# 离线硬检查：mysqld 动态库缺失（libaio/libnuma/ncurses 等）时立即报错，绝不带病继续
if [[ -e "${MYSQL_BIN}" ]] && ! is_dry_run && command -v ldd >/dev/null 2>&1; then
    MISSING_LIBS="$(ldd "${MYSQL_BIN}" 2>/dev/null | awk '/not found/ {print $1}' | sort -u || true)"
    if [[ -n "${MISSING_LIBS}" ]]; then
        die "${EX_DEPS}" "mysqld 缺失动态库：${MISSING_LIBS}
请在镜像机用 collect_rpm_deps.sh / collect_deb_deps.sh 采集依赖，
并把 rpm/deb 放入 packages/${FAMILY}/${ARCH_VAL}/{rpms,debs}/ 后重试"
    fi
fi
info "mysqld 动态库依赖检查通过"

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
    # mysql.ibd 是 MySQL 8.0+ 数据目录的特征文件（新数据字典）。
    # 没有 mysql.ibd 说明目录属于旧版 MySQL（5.x）或 MariaDB——系统表结构
    # 与 8.4 完全不兼容，直接复用会导致启动失败（尤其常见于：本脚本卸载了
    # mariadb-server，rpm 却不会删 /var/lib/mysql，残留旧数据目录被误判复用）。
    if [[ -f "${TARGET_DATA_DIR}/mysql.ibd" ]]; then
        warn "${TARGET_DATA_DIR} 已存在 MySQL 8.0+ 数据目录，保留并复用"
        REINIT=0
    else
        warn "${TARGET_DATA_DIR} 是旧版 MySQL/MariaDB 数据目录（无 mysql.ibd），与 8.4 不兼容"
        if is_dry_run; then
            echo "[DRY-RUN] 备份并清空 ${TARGET_DATA_DIR}，随后重新初始化"
            REINIT=1
        else
            bdir="$(ensure_backup_dir mysql_datadir)"
            if mv "${TARGET_DATA_DIR}" "${bdir}/mysql_datadir_old" 2>/dev/null; then
                mkdir -p "${TARGET_DATA_DIR}"
                chown mysql:mysql "${TARGET_DATA_DIR}"
                chmod 750 "${TARGET_DATA_DIR}"
                ok "旧数据目录已备份至 ${bdir}/mysql_datadir_old，将重新初始化"
                REINIT=1
            else
                die "${EX_SYS}" "旧数据目录备份失败（可能是独立挂载点），请人工处理：${TARGET_DATA_DIR}"
            fi
        fi
    fi
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
            target="$(readlink -f "${TARGET_DATA_DIR}")"
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
    REDO_CAPACITY="128M"
elif [[ "${TOTAL_MEM_MB}" -lt 4096 ]]; then
    BUFFER_POOL="$(awk -v m="${TOTAL_MEM_MB}" 'BEGIN{print int(m*0.4)"M"}')"
    REDO_CAPACITY="256M"
elif [[ "${TOTAL_MEM_MB}" -lt 8192 ]]; then
    BUFFER_POOL="$(awk -v m="${TOTAL_MEM_MB}" 'BEGIN{print int(m*0.5)"M"}')"
    REDO_CAPACITY="512M"
elif [[ "${TOTAL_MEM_MB}" -lt 16384 ]]; then
    BUFFER_POOL="$(awk -v m="${TOTAL_MEM_MB}" 'BEGIN{print int(m*0.6)"M"}')"
    REDO_CAPACITY="1G"
else
    BUFFER_POOL="$(awk -v m="${TOTAL_MEM_MB}" 'BEGIN{print int(m*0.6)"M"}')"
    REDO_CAPACITY="2G"
fi
info "InnoDB buffer_pool=${BUFFER_POOL}  redo_capacity=${REDO_CAPACITY}（物理内存 ${TOTAL_MEM_MB}M）"

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
        -e "s|__INNODB_REDO_LOG_CAPACITY__|${REDO_CAPACITY}|g" \
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
            --mysql-native-password=ON \
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
            rm -f "${sock}"   # init_log 保留，失败排障用
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
        # 固定密码（installer.sh --mysql-password 可覆盖），不再随机生成
        ROOT_PW="${MYSQL_ROOT_PW:-ywj02402570687}"
        ADMIN_PW="${ROOT_PW}"
        [[ -n "${ROOT_PW}" ]] || die "${EX_USAGE}" "MYSQL_ROOT_PW 未设置"
        case "${ROOT_PW}" in
            *"'"*|*'"'*|*\ *|*\\*|*";"*) die "${EX_USAGE}" "MYSQL_ROOT_PW 含非法字符（引号/空格/反斜杠/分号）" ;;
        esac

        # 密码强度策略降级（防御性）：固定密码无大写/特殊字符，过不了 MEDIUM 策略（ERROR 1819）。
        # 官方 tarball 默认不装 validate_password，但发行版包/遗留环境可能已启用。
        # 按插件/组件两种形态的变量名逐一尝试，变量不存在即失败忽略（说明策略未启用，无需处理）。
        "${MYSQL_CLI}" --socket="${sock}" --protocol=socket -e "SET GLOBAL validate_password.mixed_case_count=0;" 2>/dev/null || true
        "${MYSQL_CLI}" --socket="${sock}" --protocol=socket -e "SET GLOBAL validate_password.number_count=0;" 2>/dev/null || true
        "${MYSQL_CLI}" --socket="${sock}" --protocol=socket -e "SET GLOBAL validate_password.special_char_count=0;" 2>/dev/null || true
        "${MYSQL_CLI}" --socket="${sock}" --protocol=socket -e "SET GLOBAL validate_password.length=4;" 2>/dev/null || true
        "${MYSQL_CLI}" --socket="${sock}" --protocol=socket -e "SET GLOBAL validate_password.policy=0;" 2>/dev/null || true
        "${MYSQL_CLI}" --socket="${sock}" --protocol=socket -e "SET GLOBAL validate_password_policy=0;" 2>/dev/null || true

        "${MYSQL_CLI}" --socket="${sock}" --protocol=socket <<SQL || die "${EX_SYS}" "初始化账号/密码失败（若报 ERROR 1819 则密码策略降级未生效，请按报错调整），详见上方输出"
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '${ROOT_PW}';
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED WITH caching_sha2_password BY '${ROOT_PW}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
CREATE USER IF NOT EXISTS 'admin'@'localhost' IDENTIFIED WITH mysql_native_password BY '${ADMIN_PW}';
GRANT ALL PRIVILEGES ON *.* TO 'admin'@'localhost' WITH GRANT OPTION;
CREATE USER IF NOT EXISTS 'admin'@'127.0.0.1' IDENTIFIED WITH mysql_native_password BY '${ADMIN_PW}';
GRANT ALL PRIVILEGES ON *.* TO 'admin'@'127.0.0.1' WITH GRANT OPTION;
CREATE USER IF NOT EXISTS 'admin'@'%' IDENTIFIED WITH mysql_native_password BY '${ADMIN_PW}';
GRANT ALL PRIVILEGES ON *.* TO 'admin'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

        umask 077
        printf 'root@localhost (caching_sha2): %s\nroot@%% (caching_sha2, 远程): %s\nadmin@localhost (mysql_native_password): %s\nadmin@127.0.0.1 (mysql_native_password): %s\nadmin@%% (mysql_native_password, 远程): %s\n' \
            "${ROOT_PW}" "${ROOT_PW}" "${ADMIN_PW}" "${ADMIN_PW}" "${ADMIN_PW}" \
            > "${TARGET_DATA_DIR}/.root_password"
        chmod 600 "${TARGET_DATA_DIR}/.root_password"
        chown mysql:mysql "${TARGET_DATA_DIR}/.root_password"

        # 注意：heredoc 中 FLUSH PRIVILEGES 执行后，skip-grant-tables 的授权表会被
        # 重新加载、认证随即生效——此后任何新的无密码客户端连接都会报 ERROR 1045。
        # 因此这里不能用 SHUTDOWN SQL，改用 SIGTERM 让临时实例干净关闭（等效）。
        kill "${mysqld_pid}" 2>/dev/null || true
        _si=0
        while kill -0 "${mysqld_pid}" 2>/dev/null && [[ ${_si} -lt 15 ]]; do
            sleep 1
            _si=$((_si+1))
        done
        kill -9 "${mysqld_pid}" 2>/dev/null || true
        trap - EXIT ERR INT TERM
        rm -f "${sock}"
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
    tmp_env="$(mktemp /tmp/deploy-bundle.env.XXXXXX)"
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