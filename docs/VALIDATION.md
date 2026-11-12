id: /root/.trae-cn-server/bin/stable-d654d294a690adb43b5bb35d5b37adf9f292cee0-debian10/modules/ai-agent/libselinux.so.1: no version information available (required by id)
# VALIDATION.md - 交付前 family×arch 矩阵验证手册

> 目标读者：打包/交付工程师
> 目的：离线包交付给体制内无网生产环境**前**，在干净环境里验证"采集 → 部署 → 健康检查 → 回滚"全链路，确保现场零意外。
>
> **规则：任何一个 family×arch 组合没跑过本手册，就不允许向客户交付该组合的离线包。**

---

## 1. 验证矩阵

| family | arch | 镜像机参考 | 客户机代表 | 必须验证 |
| --- | --- | --- | --- | --- |
| rhel7-line | x86_64 | CentOS 7 | CentOS 7 / Kylin V10 SP1 | 是 |
| rhel8-line | x86_64 | RHEL/Rocky 8 | Kylin V10 SP2-SP3 / Anolis 8 | 是 |
| openeuler-line | x86_64 | openEuler 22.03 | openEuler 22.03/24.03 / Kylin V11 | 是 |
| deb-line | x86_64 | Ubuntu 22.04 | Ubuntu 20.04/22.04/24.04 / Debian 11/12 / UOS Desktop | 是 |
| rhel8-line | aarch64 | Rocky 8 arm | Anolis 8 arm | 是 |
| openeuler-line | aarch64 | openEuler 22.03 arm | openEuler arm / Kylin V11 arm | 是 |
| deb-line | aarch64 | Ubuntu 22.04 arm | Ubuntu arm / UOS arm | 是 |
| 任意 | aarch64 + glibc 2.17 | — | Kylin V10 SP1 鲲鹏 | **不支持，勿交付** |
| 任意 | loongarch64 | — | — | **支持已移除** |

已知限制：
- MySQL 8.4 官方 aarch64 仅发布 glibc2.28 构建 → aarch64 客户机 glibc 必须 ≥ 2.28
- loongarch64 已移除支持（install/collect 会直接拒绝）

---

## 2. 单组合验证步骤（约 30 分钟）

### 2.1 镜像机侧（联网）

```bash
# 1) 干净镜像机（与被测 family 一致）上采集
sudo TARGET_FAMILY=<family> TARGET_ARCH=<arch> bash scripts/collect.sh

# 2) 核对产物完整性
ls packages/<family>/<arch>/jdk/        # ≥1 个 OpenJDK8U-*.tar.gz
ls packages/<family>/<arch>/mysql/      # x86_64 应有 glibc2.17 + glibc2.28 双 tarball；aarch64 仅 2.28
ls packages/<family>/<arch>/tomcat/     # ≥1 个 apache-tomcat-9.x.tar.gz
ls packages/<family>/<arch>/rpms/       # rpm 系：libaio/numactl/ncurses 相关 rpm ≥1 个
ls packages/<family>/<arch>/debs/       # deb 系：libaio1(t64)/libnuma1/ncurses 相关 deb ≥1 个
```

任一目录为空 → 修复采集后再继续，**不允许空目录进入打包**。

### 2.2 客户机侧（模拟离线）

```bash
# 3) 干净虚拟机/容器：与被测 family+arch 一致的"最小化安装"（关键！最小化才暴露依赖缺失）
# 4) 切断外网（拔网线 / iptables -P OUTPUT DROP / 容器 --network=none）
# 5) 全流程部署
sudo bash installer.sh --auto

# 6) 健康检查（自动执行；也可单独跑）
sudo bash scripts/healthcheck.sh

# 7) 业务级抽查
mysql -u admin -p -e "SELECT VERSION();"   # 密码默认 ywj02402570687，必须 8.4.x
curl -I http://localhost:8080/             # 部署业务 WAR 后必须 200（404 = 未放 WAR）
ss -ltn | grep -E ':(3306|8080)'

# 7b) 应用部署抽查（如果 app/sql、app/war 有物料）
sudo bash installer.sh --only=app          # 自动建 nkw 库 + 导入 SQL + 解压 WAR + 重启

# 8) 回滚演练（验证 MANIFEST + 备份链路）
sudo bash scripts/rollback.sh --list
sudo bash scripts/rollback.sh --yes
sudo bash scripts/rollback.sh --list       # 确认已恢复
```

### 2.3 通过标准（全部满足才算 PASS）

1. `installer.sh --auto` 退出码 0，8 个 stage（含 deploy_app）全部完成
2. healthcheck 无 FAIL 项
3. `SELECT VERSION()` 返回 8.4.x；Tomcat 返回 HTTP 200（已部署业务 WAR 时）
4. `systemctl restart mysqld tomcat` 后服务自动恢复（tomcat 轻量应用应秒级；60s+ 说明应用有泄漏线程，查应用代码）
5. 回滚后系统无残留进程/服务（`ps -ef | grep -E 'mysqld|catalina'` 为空）
6. **二刷**：同一环境再跑一次 `installer.sh --auto`，幂等不报错（自管服务自动停、数据目录保留、SQL 已有表跳过）
7. context.xml 只注入一次 `clearReferencesStopThreads`（`grep -c` 结果为 1）；catalina 日志无 SAXParseException

### 2.4 记录

每个组合填写一行（留档在交付包 `docs/validation-records.md`）：

```
| family | arch | 镜像机 OS | 客户机 OS | 日期 | 执行人 | 结果 | 备注 |
```

---

## 3. 常见失败速查

| 症状 | 根因 | 处理 |
| --- | --- | --- |
| mysqld 缺失动态库 die（libaio.so.1 等） | rpms/debs 未采到依赖 | 镜像机重跑 collect.sh，确认 rpm/deb 数量 > 0 |
| `GLIBC_2.28 not found` | glibc2.28 tarball 装到了 2.17 客户机 | x86_64 确认双 tarball 都在；aarch64+2.17 组合本就不支持 |
| `GLIBCXX_x.x not found` | 客户机 libstdc++ 过老（理论不该发生，官方已静态链接） | 用 `ldd /opt/mysql/bin/mysqld` 定位，人工补 libstdc++ 包 |
| systemd 启动失败 90s 超时 | 老版本 systemd 不支持某指令 | 用 `systemd-analyze verify` 检查单元文件，回退不兼容指令 |
| apt/dnf 采集 0 个包 | 镜像机源未刷新 | `apt-get update` / `dnf makecache` 后重跑 |
| deploy_app 报"无法连接 MySQL" | mysqld systemd active 但 TCP 尚未 ready（已修复：自动重试 120s） | 确认 deploy_app.sh 含重试逻辑；仍失败查 `systemctl status mysqld` |
| 二刷报"端口 3306 已被占用" EXIT 6 | cleanup 幂等逻辑缺失（已修复：自管服务自动停） | 确认 cleanup_old.sh 含 stop_managed_services |
| 所有应用 404 且 catalina 日志有 SAXParseException "已经为元素 Context 指定属性" | context.xml 注入重复属性（已修复：单条 sed 规则） | 确认 install_tomcat.sh 的 sed 只有一条规则；手工清掉 context.xml 重复属性后 restart |
| mysqld 启动失败 / nkw 库丢失 | 数据目录是旧版 MariaDB/MySQL 5.x 遗留（无 mysql.ibd） | 新逻辑会自动搬入备份重建；手工场景：mv 数据目录 → 重跑 installer |
| Tomcat 重启 60s+ 或被 kill -9 | 应用泄漏非守护线程（MessageQueue/mysql-cj cleanup 等） | 应用代码注册 shutdown hook；脚本层已放宽到 60s + context.xml 线程回收 |
