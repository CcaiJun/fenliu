#!/bin/bash

# Nginx SNI 分流管理面板 卸载脚本
# Repository: https://github.com/CcaiJun/fenliu.git

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用 root 用户运行此脚本！\n" && exit 1

echo -e "${YELLOW}正在开始卸载 Nginx SNI 分流管理面板...${PLAIN}"

# 1. 停止并移除 Systemd 服务
echo -e "${YELLOW}正在停止服务...${PLAIN}"
systemctl stop fenliu >/dev/null 2>&1
systemctl disable fenliu >/dev/null 2>&1
rm -f /etc/systemd/system/fenliu.service
systemctl daemon-reload
echo -e "${GREEN}服务已移除${PLAIN}"

# 2. 清理本地数据
echo -e "${YELLOW}正在清理本地数据文件...${PLAIN}"
rm -f data.json app.log
echo -e "${GREEN}数据文件已清理${PLAIN}"

# 3. 移除 Nginx 关联
echo -e "${YELLOW}正在清理 Nginx 配置关联...${PLAIN}"
NGINX_CONF=""
if [[ -f "/www/server/nginx/conf/nginx.conf" ]]; then
    NGINX_CONF="/www/server/nginx/conf/nginx.conf"
    STREAM_CONF="/www/server/nginx/conf/stream-sni.conf"
elif [[ -f "/etc/nginx/nginx.conf" ]]; then
    NGINX_CONF="/etc/nginx/nginx.conf"
    STREAM_CONF="/etc/nginx/stream-sni.conf"
fi

if [[ -n "$NGINX_CONF" && -f "$NGINX_CONF" ]]; then
    # 移除 include 语句
    sed -i '/include.*stream-sni.conf/d' "$NGINX_CONF"
    # 如果 stream 块变为空，尝试清理（简单处理，保留空的 stream {} 块通常不影响）
    
    # 移除规则文件
    rm -f "$STREAM_CONF"
    echo -e "${GREEN}Nginx 关联已清理${PLAIN}"
fi

# 3. 自动还原宝塔站点配置
BT_VHOST_DIR="/www/server/panel/vhost/nginx"
if [[ -d "$BT_VHOST_DIR" ]]; then
    echo -e "${YELLOW}正在检测并还原宝塔站点端口配置...${PLAIN}"
    python3 <<EOF
import os, re

BT_VHOST_DIR = "$BT_VHOST_DIR"
reverted_count = 0

if os.path.exists(BT_VHOST_DIR):
    for filename in os.listdir(BT_VHOST_DIR):
        if filename.endswith(".conf"):
            conf_path = os.path.join(BT_VHOST_DIR, filename)
            try:
                with open(conf_path, 'r', encoding='utf-8') as f:
                    content = f.read()
                
                # 检查是否存在非 443 的 SSL 监听端口 (通常是本应用迁移产生的)
                # 匹配 listen [port] ssl; 其中 port != 443
                if re.search(r'listen\s+(?!443)\d+\s+ssl\s*;', content):
                    # 还原 listen 端口
                    new_content = re.sub(r'listen\s+\d+\s+ssl\s*;', 'listen 443 ssl;', content)
                    # 还原 server_port 判断
                    new_content = re.sub(r'if\s*\(\$server_port\s*!=\s*\d+\s*\)', 'if ($server_port != 443)', new_content)
                    # 还原 error_page 跳转 (移除端口号部分)
                    new_content = re.sub(r'error_page\s+497\s+https://\$host:\d+\$request_uri;', 'error_page 497 https://\$host\$request_uri;', new_content)
                    
                    if new_content != content:
                        with open(conf_path, 'w', encoding='utf-8') as f:
                            f.write(new_content)
                        print(f"  - 已还原站点: {filename[:-5]}")
                        reverted_count += 1
            except Exception as e:
                print(f"  - 处理 {filename} 时出错: {str(e)}")

if reverted_count > 0:
    print(f"成功还原了 {reverted_count} 个站点的配置。")
else:
    print("未发现需要还原的站点配置。")
EOF
fi

# 4. 尝试重启 Nginx 以恢复
echo -e "${YELLOW}正在尝试重启 Nginx...${PLAIN}"
# 强制杀死可能残留的 443 占用
fuser -k 443/tcp >/dev/null 2>&1
nginx -t >/dev/null 2>&1
if [ $? -eq 0 ]; then
    systemctl restart nginx >/dev/null 2>&1 || nginx -s reload >/dev/null 2>&1
    echo -e "${GREEN}Nginx 已重载并恢复正常${PLAIN}"
else
    echo -e "${RED}警告：Nginx 配置检查失败，请手动检查配置文件${PLAIN}"
fi

# 5. 提示
echo -e "\n${GREEN}卸载完成！${PLAIN}"
echo -e "您可以手动删除安装目录：${YELLOW}rm -rf $(pwd)${PLAIN}"
