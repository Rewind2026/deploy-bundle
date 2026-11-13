#!/usr/bin/env bash
# wait-for-mysql.sh - tomcat.service 的 ExecStartPre「MySQL 就绪门」
# 背景：mysqld 是 Type=simple，systemd 认为"已启动"只代表进程拉起，
#       并不代表 InnoDB 初始化完成、端口可连。仅靠 After=mysqld.service
#       无法避免 Tomcat 内应用因 MySQL 未就绪而连接失败。
# 用法：wait-for-mysql.sh [端口]   （端口占位符 __MYSQL_PORT__ 由 systemd_register.sh 替换）
# 行为：阻塞等待 127.0.0.1:<端口> 可建立 TCP 连接；超过 WAIT_FOR_MYSQL_TIMEOUT
#       （默认 300s，可在 tomcat.service 里用 Environment 覆盖）仍未就绪则以非 0
#       退出阻止 Tomcat 启动，由 systemd Restart=on-failure 稍后自动重试。
set -u

PORT="${1:-3306}"
TIMEOUT="${WAIT_FOR_MYSQL_TIMEOUT:-300}"
INTERVAL=2

probe() {
    # /dev/tcp 为 bash 内建（tomcat-stop.sh 已有同样用法），2s 超时防 SYN 挂死
    timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/${PORT}" 2>/dev/null
}

START="$(date +%s)"
DEADLINE=$(( START + TIMEOUT ))
until probe; do
    if (( "$(date +%s)" >= DEADLINE )); then
        echo "wait-for-mysql: MySQL 127.0.0.1:${PORT} 在 ${TIMEOUT}s 内未就绪，阻止 Tomcat 启动（systemd 稍后将自动重试）" >&2
        exit 1
    fi
    sleep "${INTERVAL}"
done

echo "wait-for-mysql: MySQL 127.0.0.1:${PORT} 已就绪（等待 $(( $(date +%s) - START ))s）" >&2
exit 0
