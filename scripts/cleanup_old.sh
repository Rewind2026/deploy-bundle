#!/usr/bin/env bash
# cleanup_old.sh - 旧版本检测与安全卸载

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
# 读取 installer.sh 写入的参数（DEPLOY_MODE=auto 时跳过交互确认）
[[ -f /opt/deploy-bundle.env ]] && source /opt/deploy-bundle.env || true

stage_begin "cleanup_old"
require_detect
require_root
load_detect_cache

FAMILY="$(os_family)"
ARCH_VAL="$(arch)"
PKG_MGR_VAL="$(pkg_mgr)"
BACKUP_DIR="$(ensure_backup_dir cleanup_old)"
info "本次备份目录：${BACKUP_DIR}"

list_rpm() { rpm -qa 2>/dev/null | grep -E "$1" || true; }
list_deb() { dpkg -l 2>/dev/null | awk '/^ii/ {print $2}' | grep -E "$1" || true; }

list_old_packages() {
    case "${PKG_MGR_VAL}" in
        rpm) list_rpm "$1" ;;
        dpkg) list_deb "$1" ;;
        *) err "未知包管理器：${PKG_MGR_VAL}" ;;
    esac
}

confirm() {
    local msg="$1"
    if [[ "${DEPLOY_MODE}" == "auto" ]]; then info "[auto] ${msg}"; return 0; fi
    if [[ ! -t 0 ]]; then info "[non-tty] ${msg}"; return 0; fi
    local ans
    read -r -p "$(echo "${msg} [y/N]: ")" ans
    [[ "${ans}" =~ ^[Yy]([Ee][Ss])?$ ]]
}

remove_packages() {
    local pkgs=("$@")
    [[ ${#pkgs[@]} -eq 0 ]] && { warn "无包需要卸载"; return 0; }
    info "准备卸载：${pkgs[*]}"
    case "${PKG_MGR_VAL}" in
        rpm)
            if have_cmd dnf; then
                run dnf -y remove "${pkgs[@]}" || run rpm -e --nodeps "${pkgs[@]}" || die "${EX_CLEANUP}" "卸载失败：${pkgs[*]}"
            elif have_cmd yum; then
                run yum -y remove "${pkgs[@]}" || run rpm -e --nodeps "${pkgs[@]}" || die "${EX_CLEANUP}" "卸载失败：${pkgs[*]}"
            else
                run rpm -e --nodeps "${pkgs[@]}" || die "${EX_CLEANUP}" "rpm 卸载失败：${pkgs[*]}"
            fi ;;
        dpkg)
            run dpkg -P "${pkgs[@]}" || run dpkg --purge "${pkgs[@]}" || run apt-get -y purge "${pkgs[@]}" \
                || die "${EX_CLEANUP}" "dpkg 卸载失败：${pkgs[*]}" ;;
        *) die "${EX_SYS}" "未知包管理器：${PKG_MGR_VAL}" ;;
    esac
}

# 重复部署支持：本工具自己注册的 mysqld/tomcat 服务（Description 含 "deploy-bundle managed"）
# 在重复执行 installer 时必须先停掉释放端口，否则 handle_ports 会把上次部署的
# mysqld 误判为"端口占用者"直接失败（EXIT 6）。停服但保留单元文件，
# 后续 systemd_register 阶段会重新注册并启动（数据目录 /var/lib/mysql 保留，不影响已有数据）。
stop_managed_services() {
    local unit
    for unit in mysqld tomcat; do
        local svc_file="/etc/systemd/system/${unit}.service"
        [[ -f "${svc_file}" ]] || continue
        grep -q "deploy-bundle managed" "${svc_file}" 2>/dev/null || continue
        if is_dry_run; then echo "[DRY-RUN] systemctl stop/disable ${unit}（deploy-bundle 自管，重复部署）"; continue; fi
        info "检测到本工具已部署的 ${unit} 服务，停止以支持重复部署"
        systemctl stop "${unit}" 2>/dev/null || true
        systemctl disable "${unit}" 2>/dev/null || true
    done
    # 等待端口真正释放（进程退出），最多 30 秒
    local waited=0
    while (( waited < 30 )); do
        local busy=0
        [[ "${SKIP_MYSQL:-0}" -eq 0 ]] && port_in_use "${MYSQL_PORT:-3306}" && busy=1
        [[ "${SKIP_TOMCAT:-0}" -eq 0 ]] && port_in_use "${TOMCAT_PORT:-8080}" && busy=1
        [[ "${busy}" -eq 0 ]] && break
        sleep 1; waited=$((waited+1))
    done
}

# mariadb-libs 处理：tar 包版 MySQL 自带 libmysqlclient（/opt/mysql/lib），
# 不需要系统 rpm 的 mysql-community-libs，直接卸载干净。
# 用 rpm -e --nodeps / dpkg -P 单包卸载，避免 dnf remove 连带卸载 postfix、
# cronie 等依赖 libmysqlclient 的系统组件。
purge_mariadb_libs() {
    local libs=("$@")
    [[ ${#libs[@]} -eq 0 ]] && return 0
    info "卸载 mariadb-libs（--nodeps 单包，不连带卸载依赖者）：${libs[*]}"
    if is_dry_run; then echo "[DRY-RUN] rpm -e --nodeps ${libs[*]}"; return 0; fi
    case "${PKG_MGR_VAL}" in
        rpm)  run rpm -e --nodeps "${libs[@]}" || warn "mariadb-libs 卸载失败（可忽略，不影响部署）" ;;
        dpkg) run dpkg -P "${libs[@]}" 2>/dev/null || warn "mariadb-libs 卸载失败（可忽略）" ;;
    esac
    ok "mariadb-libs 已卸载"
}

backup_dir_path() {
    local src="$1"
    [[ -e "${src}" ]] || { warn "不存在：${src}"; return 0; }
    local base; base="$(basename "${src}")"
    local dest="${BACKUP_DIR}/${base}"
    info "备份 ${src} → ${dest}"
    if is_dry_run; then echo "[DRY-RUN] cp -a ${src} ${dest}"; return 0; fi
    cp -a "${src}" "${dest}" || die "${EX_SYS}" "备份失败：${src}"
    echo "${dest}"
}

remove_path() {
    local p="$1"
    [[ -e "${p}" ]] || { warn "不存在：${p}"; return 0; }
    info "移除 ${p}"
    if is_dry_run; then echo "[DRY-RUN] rm -rf ${p}"; return 0; fi
    rm -rf "${p}"
}

handle_jdk() {
    stage_begin "cleanup_jdk"
    local jvms; jvms="$(det_get DETECTED_JVMS)"
    if [[ -z "${jvms}" ]]; then info "未探测到现存 JDK"; stage_end "cleanup_jdk"; return 0; fi
    local pkg_jdks=()
    case "${PKG_MGR_VAL}" in
        rpm)
            mapfile -t pkg_jdks < <(list_rpm '(jdk|java|openjdk|temurin|zulu|bisheng|dragonwell)' | grep -E -- '-(1\.[6789]|9|10|11|12|13|14|15|16|17|18|19|20|21|22)-' || true)
            ;;
        dpkg)
            mapfile -t pkg_jdks < <(list_deb '(openjdk-[0-9]+|temurin-[0-9]+|zulu-[0-9]+)' || true)
            ;;
    esac
    local to_uninstall_pkgs=()
    # 新系统部署原则：系统自带的包版 JDK 全部卸载干净（含 1.6/1.7/1.8），
    # 只保留我们部署的 /opt/jdk。目录形式的自解压 JDK 走备份归档。
    if [[ ${#pkg_jdks[@]} -gt 0 ]]; then
        info "发现包安装的 JDK："
        printf '  %s\n' "${pkg_jdks[@]}" >&2
        to_uninstall_pkgs=("${pkg_jdks[@]}")
    fi
    if [[ ${#to_uninstall_pkgs[@]} -gt 0 ]]; then
        warn "建议卸载以下非目标 JDK 包：${to_uninstall_pkgs[*]}"
        if confirm "是否卸载上述 JDK 包"; then
            remove_packages "${to_uninstall_pkgs[@]}"
            ok "JDK 包已卸载"
        else
            warn "跳过 JDK 包卸载"
        fi
    fi
    if [[ -n "${jvms}" ]]; then
        IFS=';' read -ra path_arr <<< "${jvms}"
        local jdk_paths=()
        for p in "${path_arr[@]}"; do
            [[ -z "${p}" ]] && continue
            [[ "${p}" == "${TARGET_JDK_DIR}" ]] && continue
            jdk_paths+=("${p}")
        done
        if [[ ${#jdk_paths[@]} -gt 0 ]]; then
            warn "发现以下用户自解压 JDK 目录："
            printf '  %s\n' "${jdk_paths[@]}" >&2
            if confirm "是否备份并归档这些目录"; then
                for p in "${jdk_paths[@]}"; do backup_dir_path "${p}"; done
            else
                warn "保留这些 JDK 目录"
            fi
        fi
    fi
    stage_end "cleanup_jdk"
}

handle_mysql() {
    stage_begin "cleanup_mysql"
    local mysql_pkgs=()
    case "${PKG_MGR_VAL}" in
        # 新系统部署原则：系统自带/仓库版的 mysql、mariadb、mysql-community
        # 全部卸载干净（server/client/libs/common 都含），只留 tar 包版 /opt/mysql。
        rpm)   mapfile -t mysql_pkgs < <(list_rpm '(mysql|mariadb)' || true) ;;
        dpkg)  mapfile -t mysql_pkgs < <(list_deb '(mysql-server|mysql-client|mariadb-server|mariadb-client|mysql-community)' || true) ;;
    esac
    if [[ ${#mysql_pkgs[@]} -eq 0 ]]; then
        info "未发现非目标 MySQL/MariaDB 包"
    else
        info "发现 MySQL/MariaDB 相关包："
        printf '  %s\n' "${mysql_pkgs[@]}" >&2
        local mariadb_libs=(); local others=()
        for p in "${mysql_pkgs[@]}"; do
            if echo "${p}" | grep -qE 'mariadb-libs'; then mariadb_libs+=("${p}")
            else others+=("${p}"); fi
        done
        if [[ ${#others[@]} -gt 0 ]]; then
            warn "建议卸载：${others[*]}"
            if confirm "是否卸载"; then remove_packages "${others[@]}"; ok "已卸载"
            else warn "跳过"; fi
        fi
        if [[ ${#mariadb_libs[@]} -gt 0 ]]; then
            if confirm "是否卸载 mariadb-libs"; then purge_mariadb_libs "${mariadb_libs[@]}"
            else warn "保留 mariadb-libs"; fi
        fi
    fi
    local mysql_home; mysql_home="$(det_get EXISTING_MYSQL_HOME)"
    if [[ -n "${mysql_home}" && "${mysql_home}" != "${TARGET_MYSQL_DIR}" ]]; then
        warn "发现遗留 MySQL 安装：${mysql_home}"
        if confirm "是否备份"; then backup_dir_path "${mysql_home}"; fi
    else
        info "未发现遗留 MySQL 安装目录"
    fi
    stage_end "cleanup_mysql"
}

handle_tomcat() {
    stage_begin "cleanup_tomcat"
    local tomcat_pkgs=()
    case "${PKG_MGR_VAL}" in
        rpm)  mapfile -t tomcat_pkgs < <(list_rpm '(^tomcat$|^tomcat-)' || true) ;;
        dpkg) mapfile -t tomcat_pkgs < <(list_deb '^(tomcat[0-9]+|tomcat)$' || true) ;;
    esac
    if [[ ${#tomcat_pkgs[@]} -gt 0 ]]; then
        warn "发现 Tomcat 包：${tomcat_pkgs[*]}"
        if confirm "是否卸载（不删 webapps）"; then
            remove_packages "${tomcat_pkgs[@]}"
        else warn "跳过"; fi
    fi
    local tomcat_home; tomcat_home="$(det_get EXISTING_TOMCAT_HOME)"
    if [[ -n "${tomcat_home}" && "${tomcat_home}" != "${TARGET_TOMCAT_DIR}" ]]; then
        warn "发现遗留 Tomcat 安装：${tomcat_home}"
        if confirm "是否备份"; then backup_dir_path "${tomcat_home}"; fi
    else
        info "未发现遗留 Tomcat 安装目录"
    fi
    local svc
    for svc in /etc/systemd/system/tomcat*.service /etc/systemd/system/multi-user.target.wants/tomcat*.service; do
        [[ -e "${svc}" ]] || continue
        warn "发现 systemd 单元：${svc}"
        if confirm "是否停用并备份"; then
            if is_dry_run; then echo "[DRY-RUN] stop/disable ${svc##*/}"; continue; fi
            local unit_name; unit_name="$(basename "${svc}")"
            systemctl stop "${unit_name%.service}" 2>/dev/null || true
            systemctl disable "${unit_name%.service}" 2>/dev/null || true
            cp -a "${svc}" "${BACKUP_DIR}/"
            run rm -f "${svc}"
        fi
    done
    stage_end "cleanup_tomcat"
}

handle_ports() {
    stage_begin "cleanup_ports"
    local ports_to_check=()
    [[ "${SKIP_MYSQL}" -eq 0 ]] && ports_to_check+=("${MYSQL_PORT}:MySQL")
    [[ "${SKIP_TOMCAT}" -eq 0 ]] && ports_to_check+=("${TOMCAT_PORT}:Tomcat")
    local conflict=0
    for entry in "${ports_to_check[@]}"; do
        local port="${entry%%:*}"; local name="${entry##*:}"
        if port_in_use "${port}"; then
            # 占用进程若来自本工具的安装目录（/opt/mysql、/opt/tomcat、/opt/jdk），
            # 属于重复部署场景（例如手工启动而非 systemd），stop_managed_services
            # 没覆盖到的情况：提示但不算冲突，安装阶段会以同路径覆盖/接管。
            local owner_cmd
            owner_cmd="$(ss -ltnp "( sport = :${port}" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -n1 || true)"
            local owner_bin=""
            if [[ -n "${owner_cmd}" ]]; then
                owner_bin="$(tr '\0' ' ' < "/proc/${owner_cmd}/cmdline" 2>/dev/null || true)"
            fi
            if [[ "${owner_bin}" == */opt/mysql/* || "${owner_bin}" == */opt/tomcat/* || "${owner_bin}" == */opt/jdk/* ]]; then
                warn "端口 ${port} 由本工具安装目录下的进程占用（pid=${owner_cmd}），继续部署"
            else
                err "端口 ${port}（${name}）已被占用！"
                [[ -n "${owner_bin}" ]] && err "  占用进程：pid=${owner_cmd} ${owner_bin}"
                conflict=1
            fi
        else info "端口 ${port}（${name}）空闲"; fi
    done
    [[ "${conflict}" -eq 1 ]] && die "${EX_CLEANUP}" "端口冲突"
    stage_end "cleanup_ports"
}

stop_managed_services
handle_jdk
handle_mysql
handle_tomcat
handle_ports

ok "旧版本清理完成"
info "备份位置：${BACKUP_DIR}"
stage_end "cleanup_old"
exit "${EX_OK}"