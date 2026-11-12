#!/usr/bin/env bash
# deploy_app.sh - 自动导入 SQL + 自动解压 WAR 到 webapps/ROOT
# ----------------------------------------------------------------------------
# 使用方法（部署前把文件拷进对应目录即可，其余全自动）：
#   /opt/deploy-bundle/app/sql/*.sql   按文件名顺序导入到 nkw 库
#   /opt/deploy-bundle/app/war/*.war   解压到 /opt/tomcat/webapps/ROOT
#                                      （多个 war 时取 ROOT.war，否则必须只有一个）
# 行为说明：
#   1. 自动创建 nkw 库（utf8mb3 / utf8mb3_general_ci，已存在则跳过）
#   2. SQL 导入使用 --force 容忍 dump 自带的 CREATE DATABASE 重复语句，
#      导入后校验表数量，为 0 视为失败；单文件报错详情打印在输出/日志中
#   3. 库中已有表时跳过导入（幂等重跑安全）；如需重导请先清空该库
#   4. WAR 解压前自动备份旧 ROOT，解压后 chown tomcat:tomcat
#   5. 有变更时自动重启 tomcat 服务
# 可单独重跑：sudo bash /opt/deploy-bundle/scripts/deploy_app.sh
# 或：sudo bash installer.sh --only=app
# ----------------------------------------------------------------------------

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
# 读取 installer.sh 写入的参数（MYSQL_PORT / MYSQL_ROOT_PW / TARGET_* 等）
[[ -f /opt/deploy-bundle.env ]] && source /opt/deploy-bundle.env || true

stage_begin "deploy_app"
require_root

APP_SQL_DIR="${APP_SQL_DIR:-${DEPLOY_BUNDLE_ROOT}/app/sql}"
APP_WAR_DIR="${APP_WAR_DIR:-${DEPLOY_BUNDLE_ROOT}/app/war}"
APP_DB_NAME="${APP_DB_NAME:-nkw}"
TARGET_TOMCAT_DIR="${TARGET_TOMCAT_DIR:-/opt/tomcat}"
TARGET_JDK_DIR="${TARGET_JDK_DIR:-/opt/jdk}"

# 预置放置目录（不存在则创建，方便部署前直接拷文件）
mkdir -p "${APP_SQL_DIR}" "${APP_WAR_DIR}"

CHANGED=0

# ---- MySQL 客户端与连接 ----
MYSQL_CLI="${TARGET_MYSQL_DIR:-/opt/mysql}/bin/mysql"
[[ -x "${MYSQL_CLI}" ]] || MYSQL_CLI="$(command -v mysql || true)"
if [[ -z "${MYSQL_CLI}" ]]; then
    die "${EX_DEPS}" "未找到 mysql 客户端，无法导入 SQL"
fi

ROOT_PW="${MYSQL_ROOT_PW:-ywj02402570687}"
export MYSQL_PWD="${ROOT_PW}"   # 避免 -p 密码出现在 ps 中
MYSQL_ARGS=(-uroot -h127.0.0.1 "-P${MYSQL_PORT:-3306}" --default-character-set=utf8mb3)

# 注意：systemd 将 mysqld 标记为 active 后，TCP 端口可能尚未 ready（InnoDB 还在恢复）。
# 这里的连接探测必须带重试窗口，否则刚装完立刻进本阶段会随机失败（低配/首次启动慢的机器必现）。
MYSQL_WAIT_MAX="${MYSQL_WAIT_MAX:-60}"   # 最多等 60×2s = 120 秒
if ! is_dry_run; then
    _mw=0
    until "${MYSQL_CLI}" "${MYSQL_ARGS[@]}" -e "SELECT 1;" >/dev/null 2>&1; do
        _mw=$((_mw+1))
        if [[ ${_mw} -ge ${MYSQL_WAIT_MAX} ]]; then
            die "${EX_DEPS}" "无法连接 MySQL（root@127.0.0.1:${MYSQL_PORT:-3306}），已等待 $((MYSQL_WAIT_MAX*2)) 秒，请确认 mysqld 状态：systemctl status mysqld"
        fi
        if [[ ${_mw} -eq 1 ]]; then
            info "等待 MySQL 就绪（root@127.0.0.1:${MYSQL_PORT:-3306}）..."
        fi
        sleep 2
    done
fi

# ============================ 1. SQL 导入 ============================
mapfile -t SQL_FILES < <(find "${APP_SQL_DIR}" -maxdepth 1 -type f -name '*.sql' 2>/dev/null | sort || true)

if [[ ${#SQL_FILES[@]} -eq 0 ]]; then
    info "未发现 SQL 文件（${APP_SQL_DIR}/），跳过导入"
else
    info "创建数据库 ${APP_DB_NAME}（utf8mb3 / utf8mb3_general_ci，已存在则跳过）"
    if ! is_dry_run; then
        "${MYSQL_CLI}" "${MYSQL_ARGS[@]}" \
            -e "CREATE DATABASE IF NOT EXISTS \`${APP_DB_NAME}\` DEFAULT CHARACTER SET utf8mb3 COLLATE utf8mb3_general_ci;" \
            || die "${EX_SYS}" "创建数据库 ${APP_DB_NAME} 失败"
    fi

    if ! is_dry_run; then
        TABLE_COUNT="$("${MYSQL_CLI}" "${MYSQL_ARGS[@]}" -N \
            -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${APP_DB_NAME}';")"
    else
        TABLE_COUNT=0
    fi

    if [[ "${TABLE_COUNT}" -gt 0 ]]; then
        warn "库 ${APP_DB_NAME} 已存在 ${TABLE_COUNT} 张表，跳过 SQL 导入（如需重导请先清空该库）"
    else
        ERR_FILE="$(mktemp /tmp/deploy_app_sql_err.XXXXXX)"
        for f in "${SQL_FILES[@]}"; do
            info "导入 SQL：$(basename "${f}")"
            if is_dry_run; then
                echo "[DRY-RUN] mysql ${APP_DB_NAME} < $(basename "${f}")"
                continue
            fi
            : > "${ERR_FILE}"
            # --force：跳过 dump 文件自带的 CREATE DATABASE/USE 重复语句报错，继续执行后续语句
            if ! "${MYSQL_CLI}" "${MYSQL_ARGS[@]}" --force "${APP_DB_NAME}" < "${f}" 2> "${ERR_FILE}"; then
                die "${EX_SYS}" "导入失败（连接级错误）：$(basename "${f}")，请检查 MySQL 状态"
            fi
            if [[ -s "${ERR_FILE}" ]]; then
                warn "  导入过程有报错行（已用 --force 跳过继续，请人工核对）："
                head -n 10 "${ERR_FILE}" | sed 's/^/    /' >&2
            fi
        done
        rm -f "${ERR_FILE}"

        if ! is_dry_run; then
            TABLE_COUNT="$("${MYSQL_CLI}" "${MYSQL_ARGS[@]}" -N \
                -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${APP_DB_NAME}';")"
            if [[ "${TABLE_COUNT}" -eq 0 ]]; then
                die "${EX_SYS}" "SQL 导入后库 ${APP_DB_NAME} 中无表，请检查 SQL 文件内容与报错详情"
            fi
        fi
        ok "SQL 导入完成：${#SQL_FILES[@]} 个文件 → 库 ${APP_DB_NAME}（${TABLE_COUNT} 张表）"
        CHANGED=1
    fi
fi

# ============================ 2. WAR 部署 ============================
WAR_FILE=""
if [[ -f "${APP_WAR_DIR}/ROOT.war" ]]; then
    WAR_FILE="${APP_WAR_DIR}/ROOT.war"
else
    mapfile -t WARS < <(find "${APP_WAR_DIR}" -maxdepth 1 -type f -name '*.war' 2>/dev/null | sort || true)
    if [[ ${#WARS[@]} -eq 1 ]]; then
        WAR_FILE="${WARS[0]}"
    elif [[ ${#WARS[@]} -gt 1 ]]; then
        die "${EX_USAGE}" "${APP_WAR_DIR}/ 下有 ${#WARS[@]} 个 war 且无 ROOT.war，请只保留一个或重命名为 ROOT.war"
    fi
fi

ROOT_DIR="${TARGET_TOMCAT_DIR}/webapps/ROOT"

if [[ -z "${WAR_FILE}" ]]; then
    info "未发现 WAR 文件（${APP_WAR_DIR}/），跳过应用部署"
else
    info "部署 WAR：$(basename "${WAR_FILE}") → ${ROOT_DIR}"
    BACKUP_DIR="$(ensure_backup_dir app_war)"
    if is_dry_run; then
        echo "[DRY-RUN] 备份旧 ROOT（如有）→ 解压 ${WAR_FILE} → ${ROOT_DIR} → chown tomcat"
    else
        if [[ -e "${ROOT_DIR}" ]]; then
            cp -a "${ROOT_DIR}" "${BACKUP_DIR}/ROOT" || die "${EX_SYS}" "备份旧 ROOT 失败"
            rm -rf "${ROOT_DIR}"
        fi
        mkdir -p "${ROOT_DIR}"
        if command -v unzip >/dev/null 2>&1; then
            unzip -oq "${WAR_FILE}" -d "${ROOT_DIR}" \
                || die "${EX_SYS}" "unzip 解压失败：$(basename "${WAR_FILE}")"
        elif [[ -x "${TARGET_JDK_DIR}/bin/jar" ]]; then
            (cd "${ROOT_DIR}" && "${TARGET_JDK_DIR}/bin/jar" -xf "${WAR_FILE}") \
                || die "${EX_SYS}" "jar 解压失败：$(basename "${WAR_FILE}")"
        else
            die "${EX_DEPS}" "系统无 unzip 且未找到 ${TARGET_JDK_DIR}/bin/jar，无法解压 WAR"
        fi
        chown -R tomcat:tomcat "${ROOT_DIR}" || warn "chown ROOT 失败"
        chmod -R u+rwX,go+rX "${ROOT_DIR}"
        ok "WAR 解压完成：${ROOT_DIR}（旧版本备份：${BACKUP_DIR}）"
        CHANGED=1
    fi
fi

unset MYSQL_PWD || true

# ============================ 3. 重启 Tomcat ============================
if [[ "${CHANGED}" -eq 0 ]]; then
    info "SQL / WAR 均无变更，跳过 tomcat 重启"
    stage_end "deploy_app"
    exit "${EX_OK}"
fi

if have_systemd; then
    info "重启 tomcat 服务"
    if is_dry_run; then
        echo "[DRY-RUN] systemctl restart tomcat"
    else
        run systemctl restart tomcat.service || die "${EX_SYS}" "tomcat 重启失败，请查看 journalctl -u tomcat"
        sleep 3
        if systemctl is-active --quiet tomcat.service; then
            ok "tomcat 已重启（active），验证：curl -I http://localhost:${TOMCAT_PORT:-8080}/"
        else
            warn "tomcat 服务未 active，请排查：journalctl -u tomcat 与 ${TARGET_TOMCAT_DIR}/logs/catalina.out"
        fi
    fi
else
    warn "无 systemd，请手工重启 Tomcat："
    warn "  ${TARGET_TOMCAT_DIR}/bin/shutdown.sh && ${TARGET_TOMCAT_DIR}/bin/startup.sh"
fi

stage_end "deploy_app"
exit "${EX_OK}"
