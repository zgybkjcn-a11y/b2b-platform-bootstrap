# B2B Platform Bootstrap

公开发布目录，不包含应用源码或任何真实凭据。支持 Ubuntu 22.04/24.04 amd64。

```bash
curl -fsSL https://raw.githubusercontent.com/zgybkjcn-a11y/b2b-platform-bootstrap/main/install.sh | sudo bash
```

安装器下载文件后按 `SHA256SUMS` 校验，私有镜像通过用户提供的 `read:packages` GHCR token 拉取。完整操作见主应用仓库的 `docs/DEPLOYMENT.md`；拆分到公开仓库时应将该文档同步为本目录的部署教程。

当前临时使用可配置的 `http://公网IP:端口` 模式（默认 8080），不占用公网 80/443；以后可运行 `b2b-platform configure domain` 切换到域名 HTTPS。HTTP 不加密，只用于受限来源、小范围临时访问。

发布新版本时同时更新：

- `stable.json`
- `versions/vX.Y.Z.json` 的 `rollbackCompatibleFrom`
- `SHA256SUMS`

不得发布 `.env`、管理员临时密码、Docker credential store 或私有镜像导出文件。
