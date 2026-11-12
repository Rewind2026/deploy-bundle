# packages/ 不入库

packages/ 下是现场采集/下载的真实离线包（MySQL/Tomcat/JDK tarball +
.deb/.rpm），按 packages/<FAMILY>/<ARCH>/{jdk|mysql|tomcat|debs|rpms}/
组织。这些文件：

- 体积大（数百 MB ~ 数 GB）
- 多数受上游厂商许可证约束，不应通过 GitHub 分发
- 会在 .gitignore 中被排除（见仓库根的 .gitignore）

## 本地如何生成

```bash
# 在镜像机上
sudo bash installer.sh --only=collect --target-family=openeuler-line --target-arch=x86_64

# 完成后整个 deploy-bundle/（含 packages/）打成 zip，拷到客户机
cd .. && zip -r offline-bundle.zip deploy-bundle/ --exclude '*.git*'
```

详见 ../docs/COLLECT_PLANNING.md。