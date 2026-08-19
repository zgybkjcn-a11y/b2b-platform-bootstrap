# B2B Platform Bootstrap

公开发布目录，不包含应用源码或任何真实凭据。支持 Ubuntu 22.04/24.04 amd64。

```bash
curl -fsSL https://raw.githubusercontent.com/zgybkjcn-a11y/b2b-platform-bootstrap/main/install.sh | sudo bash
```

安装器下载文件后按 `SHA256SUMS` 校验，私有镜像通过用户提供的 `read:packages` GHCR token 拉取。完整操作见主应用仓库的 `docs/DEPLOYMENT.md`；拆分到公开仓库时应将该文档同步为本目录的部署教程。

发布新版本时同时更新：

- `stable.json`
- `versions/vX.Y.Z.json` 的 `rollbackCompatibleFrom`
- `SHA256SUMS`

不得发布 `.env`、管理员临时密码、Docker credential store 或私有镜像导出文件。
