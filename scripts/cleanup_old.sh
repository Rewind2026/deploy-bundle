#!/usr/bin/env bash
# cleanup_old.sh - 旧版本检测与安全卸载

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

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

swap_mariadb_libs() {
    if ! have_cmd dnf; then warn "无 dnf，跳过 mariadb-libs swap"; return 0; fi
    local target="mysql-community-libs"
    info "执行 dnf swap: mariadb-libs → ${target}"
    if is_dry_run; then echo "[DRY-RUN] dnf -y swap mariadb-libs ${target}"; return 0; fi
    if ! dnf -q list available "${target}" 2>/dev/null | grep -q "${target}"; then
        local local_pkg; local_pkg="$(find_package "${FAMILY}" "${ARCH_VAL}" "${target}" | head -n1 || true)"
        if [[ -z "${local_pkg}" ]]; then warn "未找到 ${target} 包，跳过 swap"; return 0; fi
        info "使用本地包：${local_pkg}"
    fi
    dnf -y swap mariadb-libs "${target}" 2>&1 | tee -a "${LOG_FILE}" || die "${EX_CLEANUP}" "mariadb-libs swap 失败"
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
            mapfile -t pkg_jdks < <(list_rpm '(jdk|java|openjdk|temurin|zulu|bisheng|dragonwell)' | grep -E '-(1\.[6789]|9|10|11|12|13|14|15|16|17|18|19|20|21|22)-' || true)
            ;;
        dpkg)
            mapfile -t pkg_jdks < <(list_deb '(openjdk-[0-9]+|temurin-[0-9]+|zulu-[0-9]+)' || true)
            ;;
    esac
    local to_uninstall_pkgs=()
    if [[ ${#pkg_jdks[@]} -gt 0 ]]; then
        info "发现包安装的 JDK："
        printf '  %s\n' "${pkg_jdks[@]}" >&2
        for p in "${pkg_jdks[@]}"; do
            if echo "${p}" | grep -qE '-(9|1[0-9]|2[0-9])-'; then
                to_uninstall_pkgs+=("${p}")
            fi
        done
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
        rpm)   mapfile -t mysql_pkgs < <(list_rpm '(mysql|mariadb)' | grep -v 'mysql-community' || true) ;;
        dpkg)  mapfile -t mysql_pkgs < <(list_deb '(mysql-server|mysql-client|mariadb-server|mariadb-client|mysql-community)' | grep -v 'mysql-community' || true) ;;
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
            warn "检测到 mariadb-libs：${mariadb_libs[*]}"
            if confirm "是否执行 swap"; then swap_mariadb_libs
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
            err "端口 ${port}（${name}）已被占用！"
            conflict=1
        else info "端口 ${port}（${name}）空闲"; fi
    done
    [[ "${conflict}" -eq 1 ]] && die "${EX_CLEANUP}" "端口冲突"
    stage_end "cleanup_ports"
}

handle_jdk
handle_mysql
handle_tomcat
handle_ports

ok "旧版本清理完成"
info "备份位置：${BACKUP_DIR}"
stage_end "cleanup_old"
exit "${EX_OK}"