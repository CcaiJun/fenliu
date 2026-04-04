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

# 2. 移除 Nginx 关联
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
    
    # 尝试重启 Nginx 以恢复
    echo -e "${YELLOW}正在尝试重启 Nginx...${PLAIN}"
    nginx -t >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        nginx -s reload >/dev/null 2>&1
        echo -e "${GREEN}Nginx 已重载并恢复正常${PLAIN}"
    else
        echo -e "${RED}警告：Nginx 配置检查失败，请手动检查 $NGINX_CONF${PLAIN}"
    fi
fi

# 3. 提示用户手动恢复站点端口（如果之前迁移过）
echo -e "\n${YELLOW}重要提示：${PLAIN}"
echo -e "如果您之前使用了“一键迁移”或手动修改过宝塔站点的端口，"
echo -e "请务必在宝塔面板中将这些站点的端口改回 ${GREEN}443${PLAIN}，否则它们将无法访问。"

echo -e "\n${GREEN}卸载完成！${PLAIN}"
echo -e "您可以手动删除安装目录：${YELLOW}rm -rf $(pwd)${PLAIN}"
