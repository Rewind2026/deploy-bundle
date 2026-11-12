# INSTALL.md - 客户现场离线部署 5 步上手

> 目标读者：客户现场实施人员 / DBA / 运维
> 阅读时间：5 分钟
> 操作时间：≤ 30 分钟
>
> **前提**：你已经拿到了 deploy-bundle 离线包（含 JDK + MySQL + Tomcat + 系统依赖）。
> 如果你手里只有 deploy-bundle 源码，**先看** [COLLECT_PLANNING.md](./COLLECT_PLANNING.md)
> 在公司有网机器上把离线包打包好再过来。

---

## 0. 收到交付包后第一步

```bash
# 把 deploy-bundle-v1.0-<family>-<arch>.tar.gz 解压到 /opt
cd /opt
sudo tar xzf /path/to/deploy-bundle-v1.0-rhel8-x86_64.tar.gz
cd deploy-bundle

# 查看版本与产物
ls packages/rhel8-line/x86_64/{jdk,mysql,tomcat,rpms}/
cat VERSION
```

确认目录里有：
- `packages/<FAMILY>/<ARCH>/jdk/` — 至少 1 个 `OpenJDK8U-*.tar.gz`
- `packages/<FAMILY>/<ARCH>/mysql/` — 至少 1 个 `mysql-*.tar.xz`（推荐 glibc2.28 + 2.17 双套）
- `packages/<FAMILY>/<ARCH>/tomcat/` — 至少 1 个 `apache-tomcat-*.tar.gz`
- `packages/<FAMILY>/<ARCH>/rpms/` 或 `debs/` — 系统依赖

如果某个目录为空，说明该组件未打包，**别硬跑 installer**，回退到交付方确认。

---

## 1. 第一次：先做 dry-run 探测（不改系统）

```bash
sudo bash installer.sh --dry-run
```

这会：
- 探测 OS 家族、架构、glibc 版本
- 列出已装 JDK/MySQL/Tomcat
- 扫描 JAVA_HOME 引用（避免误卸其他业务）
- 检查端口 3306 / 8080 是否被占用
- **不修改任何系统配置**

输出位置：`/var/log/installer_detect_<主机名>_<时间>.txt`

---

## 2. 部署：自动模式（推荐）

```bash
sudo bash installer.sh --auto
```

执行流程（按顺序跑 7 个 stage）：
1. **detect** — 环境探测（同 dry-run）
2. **cleanup** — 按"新系统部署"原则清理：系统自带 JDK（**含 1.8.x**）、MariaDB、MySQL（含仓库版 mysql-community）全部卸载；mariadb-libs 用 `rpm -e --nodeps` 单包卸载（不连带卸载 postfix/cronie 等依赖者）；旧 MySQL/MariaDB 数据目录搬入备份目录。重复部署时自动停用本工具注册的 mysqld/tomcat（数据目录保留）
3. **install** — 解包三组件、创建 mysql 用户、初始化数据目录、写 systemd unit
4. **selinux** — 仅放松 `mysqld_t` / `tomcat_t` 域（全局仍 enforcing）
5. **firewall** — 永久关闭防火墙（现场改 Tomcat 端口无需再放行；--skip-firewall 可跳过）
6. **systemd_register** — 写 `/etc/systemd/system/{mysqld,tomcat}.service` + enable + start
7. **deploy_app** — 自动建 nkw 库（utf8mb3_general_ci）+ 导入 `app/sql/*.sql` + 解压 `app/war/*.war` 到 webapps/ROOT + 重启 tomcat（--skip-app 可跳过）
8. **healthcheck** — 14+ 项端口/进程/select/Tomcat 200 检查

---

## 3. 验证

```bash
# 1. 查看健康检查报告
cat /var/log/installer_health_*.txt

# 2. 端口监听
ss -ltn | grep -E ':(3306|8080)'

# 3. MySQL 测试
mysql -u admin -p
# 默认固定密码：ywj02402570687（root/admin 同密码，--mysql-password=PW 可覆盖）
# 同时记录在 /var/lib/mysql/.root_password（mysql:mysql 0600）
mysql> SELECT VERSION();

# 4. 远程访问（默认已开启：bind-address=0.0.0.0 + root@% / admin@%）
# 老客户端（Navicat 11 等）用 admin 账号（mysql_native_password）；
# root 是 caching_sha2_password，需新版客户端/驱动

# 5. Tomcat 测试
curl -I http://localhost:8080/
# 应返回 HTTP/1.1 200（部署了 app/war 下应用后）
```

---

## 4. 部署业务应用

**部署时只需把文件放到指定目录，脚本自动完成建库 / 导入 / 解压 / 重启：**

```bash
# 1) SQL 文件按文件名顺序导入（放这里）
sudo cp your-dump.sql /opt/deploy-bundle/app/sql/

# 2) WAR 包解压到 webapps/ROOT（放这里）
sudo cp your-app.war /opt/deploy-bundle/app/war/

# 3) 执行应用部署（自动：创建 nkw 库 utf8mb3_general_ci → 导入 SQL →
#    解压 WAR → 重启 tomcat → 验证）
sudo bash /opt/deploy-bundle/installer.sh --only=app
```

行为细节：
- SQL 导入使用 `--force` 容忍 dump 自带的 `CREATE DATABASE/USE` 语句
- nkw 库已存在表时**跳过导入**（幂等；需重导请先清空该库）
- WAR 重复部署自动备份旧版本到 `/opt/deploy-bundle-backups/`
- 连接 MySQL 最多等待 120 秒（systemd active 后端口可能还没 ready）

---

## 5. 出问题？回滚

```bash
# 列出所有可回滚点
sudo bash scripts/rollback.sh --list

# 回滚到本次部署前状态（保留 MySQL 数据目录）
sudo bash scripts/rollback.sh --yes

# 彻底清理（包括 MySQL 数据目录，慎用！）
sudo bash scripts/rollback.sh --yes --purge-data
```

---

## 高级用法

### 仅跑某个 stage

```bash
sudo bash installer.sh --only=detect        # 仅探测
sudo bash installer.sh --only=cleanup       # 仅卸载旧版本
sudo bash installer.sh --only=install       # 仅安装
sudo bash installer.sh --only=healthcheck   # 仅健康检查
```

### 指定端口

```bash
sudo bash installer.sh --auto \
    --mysql-port=3307 \
    --tomcat-port=8081
```

### 跳过某个组件

```bash
sudo bash installer.sh --auto --skip-mysql      # 不动 MySQL
sudo bash installer.sh --auto --skip-tomcat     # 不动 Tomcat
sudo bash installer.sh --auto --skip-selinux    # 不调整 SELinux 策略
sudo bash installer.sh --auto --skip-firewall   # 不动防火墙
```

---

## 退出码

| Code | 含义 |
|------|------|
| 0 | 成功 |
| 1 | 用户错误（参数 / 权限） |
| 2 | 系统错误（探测/写文件失败） |
| 3 | 依赖缺失（必要工具未装） |
| 4 | SELinux 错误 |
| 5 | 网络错误（健康检查远端时） |
| 6 | 卸载错误（清理冲突） |
| 7 | 健康检查失败 |

---

## 常见问题

### Q1. 部署后 Tomcat 启动慢 / 卡住

A: 检查 `skip-name-resolve=ON` 是否写入 my.cnf。离线环境无 DNS 会导致 30s+ 启动延迟。

### Q2. Navicat 11 连不上 MySQL 8

A: 默认 root 用 `caching_sha2_password`，Navicat 11 不支持。**用脚本里创建的 admin@localhost
（mysql_native_password）**登录。或者新建业务账号时指定 `WITH mysql_native_password`。

### Q3. JDK 8u321+ 老客户端 SSL 失败

A: 已写入 `configs/java.security` 兼容补丁。客户业务用老 SSL 也能通。

### Q4. 客户机器已有 MariaDB / 系统自带 JDK

A: 按"新系统部署"原则全部卸载干净：系统自带 JDK（**含 1.8.x**，只保留 `/opt/jdk`）、
mariadb-server/mysql-server/仓库版 mysql-community 自动卸载；mariadb-libs 用
`rpm -e --nodeps` 单包卸载（不破坏 postfix/cronie 等依赖者）；旧数据目录搬入
`/opt/deploy-bundle-backups/` 后重新初始化。重复部署时本工具自己的 mysqld/tomcat
自动停用重装，**MySQL 8.0+ 数据目录（含 mysql.ibd）保留复用**，业务数据不丢。

### Q4b. 重复在同一台机器上跑 installer 会不会丢数据？

A: 不会。数据目录含 `mysql.ibd`（MySQL 8.0+ 特征）即保留复用，nkw 业务库原样保留；
只有旧版 MySQL/MariaDB 的数据目录（与 8.4 系统表不兼容）才会搬走重建。

### Q5. SELinux 不让启动 MySQL

A: 脚本会自动 `semanage permissive -a mysqld_t tomcat_t`，仅这两个域，全局仍 enforcing。等保审计合规。

### Q6. /opt 空间不够

A: 数据目录在 `/var/lib/mysql`，与 `/opt` 分开。如 `/var` 也不够，部署前先扩展。

### Q7. Tomcat 默认主页被业务方覆盖

A: server.xml 模板默认 `autoDeploy=false`，但 `unpackWARs=true`。首次启动会解包 ROOT.war，删除 `webapps/ROOT/` 即可关闭默认页。

### Q8. 我手里只有源码（没下好的 tarball），怎么部署？

A: **不能直接部署**。deploy-bundle 设计就是离线包机制。源码只用于在公司有网机器上跑 `collect.sh`
打离线包。详见 [COLLECT_PLANNING.md](./COLLECT_PLANNING.md)。

---

## 获取更多帮助

- 镜像机打包流程：[COLLECT_PLANNING.md](./COLLECT_PLANNING.md)
- 兼容性矩阵：[COMPATIBILITY.md](./COMPATIBILITY.md)
- 回滚手册：[rollback.md](./rollback.md)
- FAQ：[FAQ.md](./FAQ.md)
- 产品需求：[PRD.md](./PRD.md)
- 实施计划：[PLAN.md](./PLAN.md)
- 部署日志：`/var/log/installer_*.log`
- 部署报告：`/var/log/installer_report_*.txt`