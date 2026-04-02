# Nginx SNI 分流管理面板 (Fenliu)

这是一个基于 Python Flask 和 Vue.js 构建的轻量级 Web 管理面板，专门用于管理 Nginx 的 SNI 前置转发（SNI 分流）。它允许代理程序（如 Xray/V2Ray）与 Web 程序共享 443 端口。

## 核心功能

- **图形化管理**：通过 Web 界面轻松添加、修改和删除 SNI 转发规则。
- **自动适配宝塔**：支持一键修改宝塔站点的 Nginx 配置端口，实现无缝共用 443。
- **实时应用**：一键生成配置并重载 Nginx。
- **端口补全**：自动处理本地 (127.0.0.1) 端口映射。

## 一键安装

在服务器上运行以下命令进行安装：

```bash
cd /root
git clone https://github.com/CcaiJun/fenliu.git
cd fenliu
chmod +x install.sh
sudo ./install.sh
```

## 使用说明

1. **环境要求**：建议在安装了 Nginx（如宝塔面板）的 Debian/Ubuntu/CentOS 服务器上使用。
2. **端口占用**：面板默认运行在 `5000` 端口。
3. **安全提示**：请在生产环境中使用防火墙限制 5000 端口的访问，或通过 Nginx 反代并添加认证。

## 配合宝塔面板使用流程

1. **宝塔面板**：正常创建站点，配好 SSL 证书和反向代理。
2. **SNI 面板**：
   - 添加规则，填入域名。
   - 填入一个未被占用的“中间层端口”（如 `10003`）。
   - **勾选“自动适配宝塔站点配置”**。
   - 点击添加并“应用并重载 Nginx”。

## 仓库地址

- GitHub: [https://github.com/CcaiJun/fenliu.git](https://github.com/CcaiJun/fenliu.git)

## 作者

- **Ccaijun** (csq40611@gmail.com)
