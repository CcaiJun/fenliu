#!/bin/bash

# Nginx SNI 分流管理面板 一键安装脚本
# Repository: https://github.com/CcaiJun/fenliu.git

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用 root 用户运行此脚本！\n" && exit 1

# 检查操作系统
if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif cat /etc/issue | grep -Eqi "debian"; then
    release="debian"
elif cat /etc/issue | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /etc/issue | grep -Eqi "centos|red hat|redhat"; then
    release="centos"
elif cat /proc/version | grep -Eqi "debian"; then
    release="debian"
elif cat /proc/version | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /proc/version | grep -Eqi "centos|red hat|redhat"; then
    release="centos"
else
    echo -e "${RED}未检测到系统版本，请联系脚本作者！${PLAIN}\n" && exit 1
fi

install_base() {
    if [[ x"${release}" == x"centos" ]]; then
        yum install -y epel-release
        yum install -y python3 python3-pip wget curl git net-tools
    else
        apt-get update
        apt-get install -y python3 python3-pip wget curl git net-tools
    fi
}

setup_service() {
    echo -e "${YELLOW}正在配置 Systemd 服务以实现后台运行和开机自启...${PLAIN}"
    
    # 停止可能存在的旧服务
    systemctl stop fenliu >/dev/null 2>&1
    
    cat > /etc/systemd/system/fenliu.service <<EOF
[Unit]
Description=Nginx SNI Forwarding Manager
After=network.target nginx.service

[Service]
Type=simple
User=root
WorkingDirectory=$(pwd)
ExecStart=$(which python3) app.py
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable fenliu
    systemctl start fenliu
    
    if systemctl is-active --quiet fenliu; then
        echo -e "${GREEN}服务已成功启动并设置为开机自启 (后台运行中)${PLAIN}"
    else
        echo -e "${RED}服务启动失败，请运行 'journalctl -u fenliu -f' 查看日志${PLAIN}"
    fi
}

setup_nginx() {
    echo -e "${YELLOW}正在配置 Nginx 集成...${PLAIN}"
    
    # 自动识别 Nginx 配置路径 (针对宝塔或标准安装)
    NGINX_CONF=""
    if [[ -f "/www/server/nginx/conf/nginx.conf" ]]; then
        NGINX_CONF="/www/server/nginx/conf/nginx.conf"
        STREAM_CONF="/www/server/nginx/conf/stream-sni.conf"
    elif [[ -f "/etc/nginx/nginx.conf" ]]; then
        NGINX_CONF="/etc/nginx/nginx.conf"
        STREAM_CONF="/etc/nginx/stream-sni.conf"
    fi

    if [[ -n "$NGINX_CONF" ]]; then
        # 检查是否已经 include
        if ! grep -q "stream-sni.conf" "$NGINX_CONF"; then
            # 尝试插入到 stream 块中
            if grep -q "stream {" "$NGINX_CONF"; then
                sed -i '/stream {/a \    include '"$STREAM_CONF"';' "$NGINX_CONF"
            else
                echo -e "stream {\n    include $STREAM_CONF;\n}" >> "$NGINX_CONF"
            fi
            echo -e "${GREEN}Nginx 配置已自动关联：$NGINX_CONF${PLAIN}"
        else
            echo -e "${YELLOW}Nginx 配置已存在关联，跳过${PLAIN}"
        fi
        touch "$STREAM_CONF"
    else
        echo -e "${RED}警告：未找到 Nginx 配置文件，请手动在 nginx.conf 中添加 include${PLAIN}"
    fi
}

echo -e "${GREEN}开始安装 Nginx SNI 分流管理面板...${PLAIN}"

# 检查是否需要克隆源码
INSTALL_DIR="/root/fenliu"
if [ ! -f "app.py" ]; then
    echo -e "${YELLOW}正在初始化安装环境...${PLAIN}"
    
    # 确保基础工具已安装
    if [[ x"${release}" == x"centos" ]]; then
        yum install -y git curl wget
    else
        apt-get update && apt-get install -y git curl wget
    fi
    
    if [ -d "$INSTALL_DIR" ]; then
        echo -e "${YELLOW}检测到已有目录，正在同步代码...${PLAIN}"
        cd "$INSTALL_DIR" && git pull
    else
        echo -e "${YELLOW}正在克隆源码到 ${INSTALL_DIR}...${PLAIN}"
        git clone https://github.com/CcaiJun/fenliu.git "$INSTALL_DIR"
        cd "$INSTALL_DIR"
    fi
fi

install_base

# 安装依赖
if [[ -f "requirements.txt" ]]; then
    pip3 install -r requirements.txt --break-system-packages || pip3 install -r requirements.txt
fi

setup_nginx
setup_service

echo -e "\n${GREEN}安装完成！${PLAIN}"
echo -e "管理面板地址：${YELLOW}http://$(curl -s ifconfig.me):5000${PLAIN}"
echo -e "配置文件目录：${YELLOW}$(pwd)${PLAIN}"
echo -e "Nginx 规则文件：${YELLOW}${STREAM_CONF}${PLAIN}"
echo -e "\n请确保防火墙已放行 5000 端口以及你配置的所有后端端口。"
