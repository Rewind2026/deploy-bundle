#!/usr/bin/env bash
# systemd_register.sh - 注册 MySQL / Tomcat 为 systemd 服务

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

: "${SKIP_MYSQL:=0}"
: "${SKIP_TOMCAT:=0}"

stage_begin "systemd_register"
require_root

HAVE_SYSTEMD=0
[[ -d /run/systemd/system ]] && HAVE_SYSTEMD=1
if [[ "${HAVE_SYSTEMD}" -eq 0 ]]; then
    warn "当前系统无 systemd"
    warn "请用前台命令启动："
    warn "  MySQL:  ${TARGET_MYSQL_DIR}/bin/mysqld --defaults-file=/etc/my.cnf &"
    warn "  Tomcat: ${TARGET_TOMCAT_DIR}/bin/catalina.sh run"
    stage_end "systemd_register"
    exit "${EX_OK}"
fi

if [[ -f /opt/deploy-bundle.env ]]; then
    # shellcheck disable=SC1091
    source /opt/deploy-bundle.env
fi

if [[ "${SKIP_MYSQL}" -eq 0 ]]; then
    SVC="/etc/systemd/system/mysqld.service"
    if [[ -f "${SVC}" && ! -L "${SVC}" ]]; then
        BACKUP_DIR="$(ensure_backup_dir systemd)"
        cp -a "${SVC}" "${BACKUP_DIR}/mysqld.service.bak"
        warn "备份现有 ${SVC}"
    fi
    info "注册 ${SVC}"
    if is_dry_run; then
        echo "[DRY-RUN] write ${SVC}"
    else
        sed -e "s|__MYSQL_DATA_DIR__|${TARGET_DATA_DIR}|g" \
            -e "s|__MYSQL_HOME__|${TARGET_MYSQL_DIR:-/opt/mysql}|g" \
            "${CFG_DIR}/mysqld.service" > "${SVC}"
        chmod 644 "${SVC}"
    fi
    info "重载 systemd"
    run systemctl daemon-reload
    info "启用 + 启动 mysqld"
    run systemctl enable mysqld.service
    if run systemctl restart mysqld.service; then ok "mysqld 启动成功"
    else warn "mysqld 启动失败"; fi
fi

if [[ "${SKIP_TOMCAT}" -eq 0 ]]; then
    SVC="/etc/systemd/system/tomcat.service"
    if [[ -f "${SVC}" && ! -L "${SVC}" ]]; then
        BACKUP_DIR="$(ensure_backup_dir systemd)"
        cp -a "${SVC}" "${BACKUP_DIR}/tomcat.service.bak"
        warn "备份现有 ${SVC}"
    fi
    # 应用部署目录：优先读 install_tomcat.sh 写入的 env，兜底按 family 推导
    APP_BASE="$(grep -E '^TOMCAT_APP_BASE=' /opt/deploy-bundle.env 2>/dev/null | cut -d= -f2- || true)"
    if [[ -z "${APP_BASE}" ]]; then
        case "$(os_family 2>/dev/null || echo rhel8-line)" in
            deb-line) APP_BASE="/var/lib/tomcat/webapps" ;;
            *)        APP_BASE="/var/lib/tomcats/webapps" ;;
        esac
    fi
    # MySQL 就绪门脚本：占位符 __MYSQL_PORT__ 替换为实际端口（env 文件或默认 3306）
    if ! is_dry_run; then
        run install -d -m 0755 "${TARGET_TOMCAT_DIR}/bin"
        sed -e "s|__MYSQL_PORT__|${MYSQL_PORT:-3306}|g" \
            "${CFG_DIR}/wait-for-mysql.sh" > "${TARGET_TOMCAT_DIR}/bin/wait-for-mysql.sh"
        chmod 755 "${TARGET_TOMCAT_DIR}/bin/wait-for-mysql.sh"
        info "安装 MySQL 就绪门：${TARGET_TOMCAT_DIR}/bin/wait-for-mysql.sh（端口 ${MYSQL_PORT:-3306}）"
    fi
    info "注册 ${SVC}（应用目录：${APP_BASE}）"
    if is_dry_run; then
        echo "[DRY-RUN] write ${SVC}"
    else
        sed -e "s|__JAVA_HOME__|${TARGET_JDK_DIR}|g" \
            -e "s|__CATALINA_HOME__|${TARGET_TOMCAT_DIR}|g" \
            -e "s|__TOMCAT_USER__|tomcat|g" \
            -e "s|__TOMCAT_GROUP__|tomcat|g" \
            -e "s|__TOMCAT_APP_BASE__|${APP_BASE}|g" \
            -e "s|__MYSQL_PORT__|${MYSQL_PORT:-3306}|g" \
            "${CFG_DIR}/tomcat.service" > "${SVC}"
        chmod 644 "${SVC}"
    fi
    info "重载 systemd"
    run systemctl daemon-reload
    info "启用 + 启动 tomcat"
    run systemctl enable tomcat.service
    if run systemctl restart tomcat.service; then ok "tomcat 启动成功"
    else warn "tomcat 启动失败"; fi
fi

sleep 2
info "服务状态："
[[ "${SKIP_MYSQL}" -eq 0 ]] && systemctl status mysqld.service --no-pager -l 2>&1 | head -n 20 | sed 's/^/  [mysqld] /' >&2 || true
[[ "${SKIP_TOMCAT}" -eq 0 ]] && systemctl status tomcat.service --no-pager -l 2>&1 | head -n 20 | sed 's/^/  [tomcat] /' >&2 || true

ok "systemd 注册完成"
stage_end "systemd_register"
exit "${EX_OK}"