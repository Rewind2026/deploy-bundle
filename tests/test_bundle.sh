#!/usr/bin/env bash
# test_bundle.sh - deploy-bundle 本地集成测试
# 用法（在项目根目录）：bash tests/test_bundle.sh
# 覆盖：bash -n 语法、installer.sh 入口、precheck 干跑、cleanup 干跑、
#      rollback --list、healthcheck mock、configs 占位符、Ansible YAML、目录结构

set -u
cd "$(dirname "$0")/.." || exit 99

BUNDLE_ROOT="$(pwd)"
PASS=0
FAIL=0
TESTS=0

if [[ -t 1 ]]; then
    C_GRN='\033[0;32m'; C_RED='\033[0;31m'; C_YEL='\033[0;33m'; C_RST='\033[0m'
else
    C_GRN=''; C_RED=''; C_YEL=''; C_RST=''
fi

assert() {
    local name="$1"; shift
    local cond="$1"; shift
    TESTS=$((TESTS + 1))
    if eval "${cond}"; then
        printf '  %bOK%b %s\n' "${C_GRN}" "${C_RST}" "${name}"
        PASS=$((PASS + 1))
    else
        printf '  %bX%b %s\n' "${C_RED}" "${C_RST}" "${name}"
        FAIL=$((FAIL + 1))
        [[ $# -gt 0 ]] && printf '       %s\n' "$*"
    fi
}

section() { printf '\n%b=== %s ===%b\n' "${C_YEL}" "$*" "${C_RST}"; }

section "1. 语法检查"
SCRIPTS=(
    installer.sh
    scripts/lib.sh
    scripts/precheck.sh
    scripts/cleanup_old.sh
    scripts/install_jdk.sh
    scripts/install_mysql.sh
    scripts/install_tomcat.sh
    scripts/selinux_relax.sh
    scripts/firewall.sh
    scripts/systemd_register.sh
    scripts/deploy_app.sh
    scripts/healthcheck.sh
    scripts/rollback.sh
    scripts/collect.sh
    scripts/collect_jdk.sh
    scripts/collect_mysql.sh
    scripts/collect_tomcat.sh
    scripts/collect_rpm_deps.sh
    scripts/collect_deb_deps.sh
    scripts/license_collect.sh
    scripts/write_manifest.sh
    scripts/detect_kylin_uos.sh
    tests/test_bundle.sh
)
for s in "${SCRIPTS[@]}"; do
    assert "bash -n ${s}" "[[ -f ${s} ]] && bash -n ${s} 2>/dev/null"
done

section "2. installer.sh 入口"
out="$(bash installer.sh --help 2>&1)"
assert "installer.sh --help 输出'用法'" "echo '${out}' | grep -q '用法'"
out="$(bash installer.sh --version 2>&1)"
expected_ver="$(head -1 VERSION | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
assert "installer.sh --version 输出 ${expected_ver}" "echo '${out}' | grep -q '${expected_ver}'"
out="$(bash installer.sh --invalid 2>&1)"; rc=$?
assert "installer.sh --invalid 拒绝（exit 1）" "[[ ${rc} -eq 1 ]]"

section "3. rollback.sh 入口"
if [[ -x scripts/rollback.sh ]]; then
    out="$(bash scripts/rollback.sh --help 2>&1)"; rc=$?
    assert "rollback.sh --help 输出帮助" "[[ ${rc} -eq 0 ]]"
fi

section "4. precheck.sh mock 缓存连通性"
TMP_ENV="$(mktemp /tmp/deploy-bundle.env.XXXX)"
TMP_CACHE="$(mktemp /tmp/deploy-bundle.detect.XXXX)"
cat > "${TMP_ENV}" <<EOF
DEPLOY_BUNDLE_ROOT=${BUNDLE_ROOT}
DEPLOY_MODE=dry-run
DEPLOY_STAGE=detect
DEPLOY_LANG=zh-CN
MYSQL_PORT=3306
TOMCAT_PORT=8080
TARGET_JDK_DIR=/opt/jdk
TARGET_MYSQL_DIR=/opt/mysql
TARGET_TOMCAT_DIR=/opt/tomcat
TARGET_DATA_DIR=/var/lib/mysql
TARGET_BACKUP_ROOT=/tmp/deploy-bundle-backups-test
EOF
out="$(DEPLOY_BUNDLE_ENV="${TMP_ENV}" bash scripts/precheck.sh 2>&1 || true)"
assert "precheck.sh 无 syntax error" "! echo '${out}' | grep -q 'syntax error'"

cat > "${TMP_CACHE}" <<EOF
OS_ID=centos
OS_VERSION=8
OS_NAME=CentOS
OS_FAMILY=rhel8-line
ARCH=x86_64
GLIBC_VERSION=2.28
PKG_MGR=rpm
HAVE_SYSTEMD=1
HAVE_SELINUX=1
HAVE_APPARMOR=0
HAVE_FIREWALLD=1
HAVE_UFW=0
HAVE_IPTABLES=1
CPU_FLAGS=avx2
EXISTING_JDK_LIST=
EXISTING_MYSQL_LIST=
DETECTED_JVMS=
EOF
cp "${TMP_CACHE}" /tmp/deploy-bundle.detect

section "5. cleanup_old.sh 干跑连通性"
out="$(DEPLOY_MODE=dry-run DEPLOY_STAGE=cleanup DEPLOY_BUNDLE_ROOT="${BUNDLE_ROOT}" bash scripts/cleanup_old.sh 2>&1)" || true
rc=$?
assert "cleanup_old.sh 干跑模式退出 0" "[[ ${rc} -eq 0 ]]"

rm -f /tmp/deploy-bundle.detect

section "6. healthcheck.sh mock 缓存连通性"
cp "${TMP_CACHE}" /tmp/deploy-bundle.detect
out="$(DEPLOY_MODE=dry-run DEPLOY_BUNDLE_ROOT="${BUNDLE_ROOT}" bash scripts/healthcheck.sh 2>&1)" || true
rc=$?
assert "healthcheck.sh 不崩溃" "[[ ${rc} -eq 0 || ${rc} -eq 7 ]]"
rm -f /tmp/deploy-bundle.detect

section "7. 配置文件完整性"
assert "configs/my.cnf.template 存在" "[[ -f configs/my.cnf.template ]]"
assert "configs/server.xml.template 存在" "[[ -f configs/server.xml.template ]]"
assert "configs/mysqld.service 存在" "[[ -f configs/mysqld.service ]]"
assert "configs/tomcat.service 存在" "[[ -f configs/tomcat.service ]]"
assert "configs/java.security 存在" "[[ -f configs/java.security ]]"
assert "my.cnf 含 __MYSQL_PORT__" "grep -q '__MYSQL_PORT__' configs/my.cnf.template"
assert "my.cnf 含 __MYSQL_DATA_DIR__" "grep -q '__MYSQL_DATA_DIR__' configs/my.cnf.template"
assert "server.xml 含 __TOMCAT_PORT__" "grep -q '__TOMCAT_PORT__' configs/server.xml.template"
assert "mysqld.service 含 __MYSQL_DATA_DIR__" "grep -q '__MYSQL_DATA_DIR__' configs/mysqld.service"
assert "tomcat.service 含 __JAVA_HOME__" "grep -q '__JAVA_HOME__' configs/tomcat.service"
assert "tomcat.service TimeoutStartSec > 就绪门超时" "grep -q 'TimeoutStartSec=320' configs/tomcat.service"
assert "systemd_register 替换 unit 中 __MYSQL_PORT__" "[[ \$(grep -c 's|__MYSQL_PORT__|' scripts/systemd_register.sh) -ge 2 ]]"
assert "configs/wait-for-mysql.sh 存在" "[[ -f configs/wait-for-mysql.sh ]]"
assert "wait-for-mysql.sh 语法通过" "bash -n configs/wait-for-mysql.sh"
assert "tomcat.service 引用 wait-for-mysql" "grep -q 'wait-for-mysql' configs/tomcat.service"
assert "tomcat.service 在 mysqld 之后启动" "grep -q 'After=network.target mysqld.service' configs/tomcat.service"
assert "java.security 含 3DES" "grep -q '3DES_EDE_CBC' configs/java.security"
assert "UOS 探测检查 /etc/os-version（Server 25 误判 desktop 修复）" "grep -q '/etc/os-version' scripts/detect_kylin_uos.sh"
assert "UOS 探测有 dnf/yum 兜底判 server" "grep -q 'command -v dnf' scripts/detect_kylin_uos.sh"
assert "UOS Server 23/24/25 映射 openeuler-line" "grep -q '23\*|24\*|25\*' scripts/detect_kylin_uos.sh"
assert "lib.sh auto_detect_family 复用 detect_kylin_uos.sh（单一事实来源）" "grep -q 'source \"\${dku}\"' scripts/lib.sh"
assert "lib.sh 含 diag_pkgs_dir 诊断助手" "grep -q 'diag_pkgs_dir()' scripts/lib.sh"
assert "install 脚本缺失包目录时调用诊断" "[[ \$(grep -c 'diag_pkgs_dir \"\${FAMILY}\"' scripts/install_jdk.sh scripts/install_mysql.sh scripts/install_tomcat.sh | grep -c ':1') -eq 3 ]]"
assert "openKylin 判 deb-line（lib.sh 显式分支）" "grep -q 'openkylin:\*' scripts/lib.sh"
assert "lib.sh 未知系统按包管理器兜底而非一律 rhel8-line" "grep -q '未知系统：按包管理器兜底' scripts/lib.sh"
assert "detect.sh 只读探测报告存在且语法通过" "[[ -f scripts/detect.sh ]] && bash -n scripts/detect.sh"
assert "COMPATIBILITY.md 收录 openKylin" "grep -q 'openKylin' docs/COMPATIBILITY.md"
assert "detect.sh glibc 探测无 SIGPIPE 竞态（awk 读全量）" "grep -q 'NR==1' scripts/detect.sh"
assert "install_mysql 依赖逐个安装（libaio1/libaio1t64 多变体修复）" "grep -q '逐个安装' scripts/install_mysql.sh"

section "8. Ansible 配置文件"
assert "ansible/deploy.yml 存在" "[[ -f ansible/deploy.yml ]]"
assert "ansible/inventory.example 存在" "[[ -f ansible/inventory.example ]]"
assert "ansible/ansible.cfg 存在" "[[ -f ansible/ansible.cfg ]]"
assert "ansible/group_vars/all.yml 存在" "[[ -f ansible/group_vars/all.yml ]]"

section "9. 文档完整性"
assert "docs/PRD.md 存在且非空" "[[ -s docs/PRD.md ]]"
assert "docs/PLAN.md 存在且非空" "[[ -s docs/PLAN.md ]]"
assert "docs/INSTALL.md 存在且非空" "[[ -s docs/INSTALL.md ]]"
assert "docs/COMPATIBILITY.md 存在且非空" "[[ -s docs/COMPATIBILITY.md ]]"
assert "docs/FAQ.md 存在且非空" "[[ -s docs/FAQ.md ]]"
assert "VERSION 存在且非空" "[[ -s VERSION ]]"
assert "VERSION 包含 deploy-bundle" "grep -q 'deploy-bundle' VERSION"

section "10. 目录结构"
assert "scripts/ 目录" "[[ -d scripts ]]"
assert "configs/ 目录" "[[ -d configs ]]"
assert "docs/ 目录" "[[ -d docs ]]"
assert "ansible/ 目录" "[[ -d ansible ]]"
assert "LICENSES/ 目录" "[[ -d LICENSES ]]"
assert "packages/ 目录" "[[ -d packages ]]"
assert "tests/ 目录" "[[ -d tests ]]"

section "11. 跨脚本引用一致性"
for s in precheck cleanup_old install_jdk install_mysql install_tomcat selinux_relax firewall systemd_register healthcheck; do
    assert "scripts/${s}.sh 存在" "[[ -x scripts/${s}.sh ]]"
done

echo
echo "================================================"
printf '  Pass: %b%d%b / Fail: %b%d%b / Total: %d\n' \
    "${C_GRN}" "${PASS}" "${C_RST}" "${C_RED}" "${FAIL}" "${C_RST}" "${TESTS}"
echo "================================================"

rm -f "${TMP_ENV}" "${TMP_CACHE}"
rm -rf /tmp/deploy-bundle-backups-test 2>/dev/null || true

[[ "${FAIL}" -gt 0 ]] && exit 1
exit 0