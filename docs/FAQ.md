# FAQ (常见问题)

## Q0: deploy-bundle 的部署流程是什么? 是要先打包还是直接部署?

A: **先打包，再部署**，分两步：

```
[公司镜像机(有网)]              ->   [客户机器(无外网)]
   跑 collect.sh                     跑 installer.sh
   产物 packages/<FAMILY>/<ARCH>/ +
   LICENSES/ 拷到客户机器
```

详见 [COLLECT_PLANNING.md](./COLLECT_PLANNING.md)。

## Q1: 客户的服务器无法联网，怎么传 bundle?

A: bundle 本身离线自包含。常见传输：U盘 / 内网跳板机 SCP / 网闸。
只要把整个 `/opt/deploy-bundle/` 目录（含 packages/、LICENSES/）原样放到客户机器的 `/opt/` 下即可。

## Q2: 客户机器只能让 tar 包，不能让 RPM 包?

A: MySQL / Tomcat / JDK 全部用通用二进制 tar.xz 安装。唯一用 RPM/DEB 的是运行时依赖 (libaio / numactl)，
且两套都备：`packages/<family>/<arch>/rpms/` (rhel/openeuler) 或 `debs/` (deb)。

## Q3: 客户已有 mariadb-libs (PostgreSQL 依赖)

A: `cleanup_old.sh` 检测到 `mariadb-libs` 时默认保留，并询问是否执行 `dnf swap mariadb-libs mysql-community-libs`。

## Q4: 客户不允许执行 dnf/yum

A: `cleanup_old.sh` 所有 `dnf remove` 都有 fallback 到 `rpm -e --nodeps`。

## Q5: 客户的端口被占用

A: `sudo bash installer.sh --mysql-port=3307 --tomcat-port=8081`，自动检测新端口冲突、注册 SELinux。

## Q6: 客户的 systemd 不能 enable (容器/chroot)

A: `systemd_register.sh` 检测 `/run/systemd/system` 不存在时自动跳过，提示前台启动命令。

## Q7: 客户不允许写 /etc/systemd/system

A: 当前未实现。可手工改 `systemd_register.sh` 加 `SKIP_SYSTEMD` 开关。

## Q8: 客户有 SELinux enforcing 且不允许打 permissive

A: deploy-bundle 仅对 mysqld_t / tomcat_t 两个域打 permissive，全局仍是 enforcing。
仍不接受：`sudo bash installer.sh --skip-selinux` 然后人工 `ausearch -m avc`。

## Q9: 客户的 JAVA_HOME 引用

A: precheck 扫描 `/opt /usr/local /etc/systemd/system` 下的 JAVA_HOME 引用并打印。部署后不会自动改。

## Q10: MySQL 8 caching_sha2_password 老客户端不兼容

A: 已创建 `admin@localhost` 后备账户（mysql_native_password）。Navicat 11 之前用 admin 登录。
强制：编辑 `configs/my.cnf.template` 加 `default_authentication_plugin=mysql_native_password`。

## Q11: Tomcat 启动后 8080 报 403/404

A: deploy-bundle 默认清空 Tomcat 自带 webapps。需部署应用：`sudo cp /path/to/ROOT.war /var/lib/tomcat/webapps/`。

## Q12: 客户 glibc 是 2.23

A: MySQL tarball 选 glibc2.17（向下兼容）。

## Q13: collect.sh 在公司网络无法下载 Adoptium Temurin

A: 设置环境变量走清华镜像:
```bash
export DEPLOY_MIRROR_ADOPTIUM=https://mirrors.tuna.tsinghua.edu.cn/Adoptium
export DEPLOY_MIRROR_MYSQL=https://mirrors.tuna.tsinghua.edu.cn/mysql
export DEPLOY_MIRROR_TOMCAT=https://mirrors.tuna.tsinghua.edu.cn/apache/tomcat
```

## Q14: bundle 体积太大 (>5GB)

A: 单 family+arch 约 1.0 GB，多 family 5 family + 2 arch 约 5 GB。裁剪：`rm -rf packages/rhel7-line packages/openeuler-line`。

## Q15: 客户的 OS 不在兼容表 (如 FreeBSD)

A: 阶段 3 不支持。后续可扩展：
1. precheck.sh 添加 OS family 识别
2. collect.sh 添加依赖收集路径
3. 测试覆盖

## Q16: 为什么 MySQL 用通用二进制而非 RPM?

A: 通用二进制跨发行版一致，部署/卸载干净。代价：包体积大 (400MB / glibc)。

## Q17: 怎么升级 deploy-bundle 自己?

A: deploy-bundle 无状态。直接覆盖 `/opt/deploy-bundle/` 目录即可。

## Q18: 客户的 loongarch64 机器

A: 阶段 3 不支持。手工提供龙芯 JDK + 通用二进制 MySQL + Tomcat。修改 `precheck.sh` OS_FAMILY 映射。

## Q19: JDK 8 + Tomcat 9 启动慢

A: deploy-bundle 已注入 `securerandom.source=file:/dev/./urandom`。

## Q20: 怎么集成到客户运维平台

A: 用 Ansible Tower / 自研平台调用 `ansible-playbook -i inventory deploy.yml`。

## Q21: 镜像机的 OS 一定要和客户机一样吗?

A: **family 必须一样，arch 必须一样**。OS minor 版本无关 (如 RHEL 8.4 镜像机可服务 RHEL 8.10 / Rocky 8 / Anolis 8 / Kylin V10 SP3 / openEuler 24.03 客户机)。
如果客户机 family 不在范围，参考 COLLECT_PLANNING §2.2。

## Q22: 一台镜像机能同时产多个 family 的包吗?

A: **不能**。`repotrack` / `apt-get download` 是从镜像机的本地仓库拉 RPM/DEB。
要支持多 family 需要多台镜像机。

## Q23: 能否在客户机上现下 tarball?

A: 强烈不建议。客户机无外网或网络受限，下载失败率高。

## Q24: bundle 体积多大？

A: 单 family+arch 约 1.0 GB。
```bash
tar czf deploy-bundle-v1.0-rhel8-x86_64.tar.gz /opt/deploy-bundle
```

## Q25: JDK / MySQL / Tomcat 想升级版本号

A: 在镜像机重新跑 collect.sh，指定版本号:
```bash
sudo bash scripts/collect.sh --family=rhel8-line --arch=x86_64 --jdk=8u512
sudo bash scripts/collect.sh --family=rhel8-line --arch=x86_64 --mysql=8.0.42
sudo bash scripts/collect.sh --family=rhel8-line --arch=x86_64 --tomcat=9.0.95
```

## Q26: 客户机 family 不在镜像机清单里 (Anolis 23、openEuler 24.03)

A: 可以近似救场:
1. Anolis 23 -> 选 RHEL 9 镜像机 (`--family=openeuler-line`)
2. openEuler 24.03 -> 选 RHEL 9 镜像机 (`--family=openeuler-line`)
3. UOS 服务器 (apt-rpm) -> 选 RHEL 8 镜像机 (`--family=rhel8-line`)
4. Deepin -> 选 Debian 镜像机 (`--family=deb-line`)