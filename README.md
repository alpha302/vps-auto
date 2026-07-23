# vps-auto

Ubuntu VPS 初始化脚本 [`vps_auto_work_cc.sh`](vps_auto_work_cc.sh) 的**公开分发仓库**。

开发在私有仓 [MyTools](https://github.com/alpha302/MyTools) 进行；本仓库仅用于 VPS 拉取安装与自更新。

## 首次安装

```bash
curl -fsSL https://raw.githubusercontent.com/alpha302/vps-auto/main/install.sh | sudo bash
```

脚本将安装到 `/root/.1/vps_auto_work_cc.sh` 与 `/root/.1/install-tools.sh`（供 `-mcp-apt` 使用）。

## 检查 / 更新

```bash
sudo bash /root/.1/vps_auto_work_cc.sh -update-check
sudo bash /root/.1/vps_auto_work_cc.sh -update
```

`-update` 会下载新版本、执行 `bash -n` 与 SHA256 校验，并备份旧文件（`*.bak.YYYYMMDDHHMMSS`）。

## 版本信息

当前版本见 [`version.json`](version.json)。

## 可选配置

创建 `/etc/vps_auto/update.conf` 可覆盖默认地址：

```bash
MANIFEST_URL="https://raw.githubusercontent.com/alpha302/vps-auto/main/version.json"
INSTALL_PATH="/root/.1/vps_auto_work_cc.sh"
```
