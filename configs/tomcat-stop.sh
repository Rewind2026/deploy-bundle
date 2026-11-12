#!/usr/bin/env bash
# tomcat-stop.sh - Tomcat 优雅停机脚本（deploy-bundle 生成）
# 背景：catalina.sh stop 的等待时长写死 5 秒，偏重的 Spring 应用停不干净
#       会被过早 kill -9。本脚本发送 SHUTDOWN 命令后最多等待 60 秒，超时才强杀。
# 由 tomcat.service 的 ExecStop 调用，也可手工执行：/opt/tomcat/bin/tomcat-stop.sh

set -u
CATALINA_HOME="${CATALINA_HOME:-/opt/tomcat}"
PID_FILE="${CATALINA_PID:-${CATALINA_HOME}/temp/tomcat.pid}"
WAIT_MAX="${TOMCAT_STOP_WAIT:-60}"

[[ -f "${PID_FILE}" ]] || exit 0
PID="$(cat "${PID_FILE}" 2>/dev/null || true)"
if [[ -z "${PID}" ]] || ! kill -0 "${PID}" 2>/dev/null; then
    exit 0
fi

# 从 server.xml 读取 shutdown 端口与指令，发送 SHUTDOWN 触发优雅停机
SHUTDOWN_PORT="$(awk -F'"' '/<Server[[:space:]]/ {print $2; exit}' "${CATALINA_HOME}/conf/server.xml" 2>/dev/null || true)"
SHUTDOWN_CMD="$(awk -F'"' '/<Server[[:space:]]/ {print $4; exit}' "${CATALINA_HOME}/conf/server.xml" 2>/dev/null || true)"
if [[ -n "${SHUTDOWN_PORT}" && -n "${SHUTDOWN_CMD}" ]]; then
    (printf '%s\n' "${SHUTDOWN_CMD}"; sleep 1) \
        | timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/${SHUTDOWN_PORT} && cat >&3" 2>/dev/null || true
fi

for _i in $(seq 1 "${WAIT_MAX}"); do
    kill -0 "${PID}" 2>/dev/null || exit 0
    sleep 1
done

# 超时兜底强杀
kill -9 "${PID}" 2>/dev/null || true
exit 0
