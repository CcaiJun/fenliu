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

setup_firewall() {
    echo -e "${YELLOW}正在尝试自动开放防火墙端口 $PANEL_PORT...${PLAIN}"
    if command -v ufw >/dev/null 2>&1; then
        ufw allow $PANEL_PORT/tcp >/dev/null 2>&1
        echo -e "${GREEN}UFW 端口 $PANEL_PORT 已放行${PLAIN}"
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --zone=public --add-port=$PANEL_PORT/tcp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        echo -e "${GREEN}Firewalld 端口 $PANEL_PORT 已放行${PLAIN}"
    else
        echo -e "${YELLOW}未检测到 UFW 或 Firewalld，请手动放行端口 $PANEL_PORT${PLAIN}"
    fi
}

generate_initial_config() {
    echo -e "${YELLOW}正在生成初始 Nginx 配置...${PLAIN}"
    python3 -c "import app; app.generate_nginx_config(app.load_data())" 2>/dev/null
}

setup_data_json() {
    DATA_FILE="data.json"
    if [[ ! -f "$DATA_FILE" ]]; then
        echo '{"listen_port": 443, "routes": []}' > "$DATA_FILE"
    fi
    # 使用 python3 修改 data.json 中的面板端口字段 panel_port
    python3 -c "import json, os; \
        data = json.load(open('$DATA_FILE')); \
        data['panel_port'] = $PANEL_PORT; \
        json.dump(data, open('$DATA_FILE', 'w'), indent=2)" 2>/dev/null
}

check_and_migrate_bt_sites() {
    BT_VHOST_DIR="/www/server/panel/vhost/nginx"
    if [[ ! -d "$BT_VHOST_DIR" ]]; then
        return
    fi

    # 查找所有监听 443 端口的站点
    SITES_443=$(grep -l "listen 443 ssl" "$BT_VHOST_DIR"/*.conf 2>/dev/null)
    if [[ -z "$SITES_443" ]]; then
        return
    fi

    echo -e "\n${YELLOW}检测到以下宝塔站点当前正在占用 443 端口：${PLAIN}"
    for site_conf in $SITES_443; do
        basename "$site_conf" .conf
    done

    echo -e "\n${YELLOW}为了防止 443 端口冲突，是否一键将这些站点迁移到本应用的分流转发？(y/n)${PLAIN}"
    read -p "选择: " migrate_confirm < /dev/tty
    if [[ "$migrate_confirm" != "y" && "$migrate_confirm" != "Y" ]]; then
        echo -e "${YELLOW}已跳过自动迁移。请务必在安装后通过管理面板手动处理这些域名的端口冲突。${PLAIN}"
        return
    fi

    echo -e "${YELLOW}正在自动迁移站点配置...${PLAIN}"
    
    python3 <<EOF
import os, re, json, uuid

BT_VHOST_DIR = "$BT_VHOST_DIR"
DATA_FILE = "data.json"
SITES_443 = "$SITES_443".split()

def patch_conf(domain, port):
    conf_path = os.path.join(BT_VHOST_DIR, f"{domain}.conf")
    with open(conf_path, 'r', encoding='utf-8') as f:
        content = f.read()
    content = re.sub(r'listen\s+443\s+ssl\s*;', f'listen {port} ssl;', content)
    content = re.sub(r'if\s*\(\$server_port\s*!=\s*443\s*\)', f'if ($server_port != {port})', content)
    content = re.sub(r'error_page\s+497\s+https://\$host\$request_uri;', f'error_page 497 https://\$host:{port}\$request_uri;', content)
    with open(conf_path, 'w', encoding='utf-8') as f:
        f.write(content)

with open(DATA_FILE, 'r') as f:
    data = json.load(f)

start_port = 10001
# 查找当前最大的后端端口
for r in data.get('routes', []):
    try:
        p = int(r['backend_server'].split(':')[-1])
        if p >= start_port: start_port = p + 1
    except: pass

for site_conf in SITES_443:
    domain = os.path.basename(site_conf).replace('.conf', '')
    if any(r['domain'] == domain for r in data['routes']):
        print(f"  - {domain} 已在分流规则中，跳过")
        continue
    
    port = start_port
    start_port += 1
    
    try:
        patch_conf(domain, port)
        new_route = {
            "id": str(uuid.uuid4())[:8],
            "domain": domain,
            "backend_name": re.sub(r'[^a-zA-Z0-9_]', '_', domain) + "_bt",
            "backend_server": f"127.0.0.1:{port}"
        }
        data['routes'].append(new_route)
        print(f"  - {domain} 成功迁移到端口 {port}")
    except Exception as e:
        print(f"  - {domain} 迁移失败: {str(e)}")

with open(DATA_FILE, 'w') as f:
    json.dump(data, f, indent=2)
EOF

    echo -e "${GREEN}自动迁移完成！${PLAIN}"
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
    
    # 自动识别 Nginx 配置路径
    NGINX_CONF=""
    STREAM_CONF=""
    
    # 优先检查常见路径
    if [[ -f "/www/server/nginx/conf/nginx.conf" ]]; then
        NGINX_CONF="/www/server/nginx/conf/nginx.conf"
    elif [[ -f "/etc/nginx/nginx.conf" ]]; then
        NGINX_CONF="/etc/nginx/nginx.conf"
    elif [[ -f "/usr/local/nginx/conf/nginx.conf" ]]; then
        NGINX_CONF="/usr/local/nginx/conf/nginx.conf"
    else
        # 尝试通过 nginx -V 查找
        NGINX_CONF=$(nginx -V 2>&1 | grep -oP "conf-path=\K[^ ]*")
        if [[ ! -f "$NGINX_CONF" ]]; then
            # 最后的尝试：find
            NGINX_CONF=$(find /etc /usr/local /www -name "nginx.conf" 2>/dev/null | head -n 1)
        fi
    fi

    if [[ -n "$NGINX_CONF" ]]; then
        # 规则文件放在 nginx.conf 同级目录
        CONF_DIR=$(dirname "$NGINX_CONF")
        STREAM_CONF="$CONF_DIR/stream-sni.conf"
        
        # 检查是否已经 include
        if ! grep -q "stream-sni.conf" "$NGINX_CONF"; then
            # 尝试插入到 stream 块中
            if grep -q "stream {" "$NGINX_CONF"; then
                sed -i '/stream {/a \    include '"$STREAM_CONF"';' "$NGINX_CONF"
            else
                # 如果没有 stream 块，添加到文件末尾
                echo -e "\nstream {\n    include $STREAM_CONF;\n}" >> "$NGINX_CONF"
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

# 1. 确认前置环境
echo -e "${YELLOW}重要提示：本应用需要配合 宝塔面板 (BT-Panel) 和 Nginx 使用。${PLAIN}"
read -p "您是否已在服务器上安装了宝塔面板和 Nginx？(y/n): " confirm < /dev/tty
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo -e "${RED}安装已取消。请先安装宝塔面板和 Nginx 后再试。${PLAIN}"
    exit 1
fi

# 2. 选择安装端口
read -p "请输入管理面板运行端口 (默认 5000): " PANEL_PORT < /dev/tty
PANEL_PORT=${PANEL_PORT:-5000}

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

setup_data_json
check_and_migrate_bt_sites
setup_nginx
generate_initial_config
setup_service
setup_firewall

echo -e "\n${GREEN}安装完成！${PLAIN}"

# 获取 IP 地址 (优先 IPv4)
SERVER_IP=$(curl -s4 ifconfig.me || curl -s ifconfig.me)
if [[ "$SERVER_IP" == *":"* ]]; then
    # 如果是 IPv6，添加中括号
    DISPLAY_IP="[$SERVER_IP]"
else
    DISPLAY_IP="$SERVER_IP"
fi

echo -e "管理面板地址：${YELLOW}http://$DISPLAY_IP:$PANEL_PORT${PLAIN}"
echo -e "配置文件目录：${YELLOW}$(pwd)${PLAIN}"
echo -e "Nginx 规则文件：${YELLOW}${STREAM_CONF:-"未自动关联，请手动配置"}${PLAIN}"
echo -e "\n${YELLOW}提示：${PLAIN}"
echo -e "1. 如果看到 'pip root user' 警告，属于正常现象，依赖已正确安装。"
echo -e "2. 请确保防火墙已放行 $PANEL_PORT 端口（脚本已尝试自动开放）。"
echo -e "3. Nginx 配置文件中必须包含 stream 模块支持 (已自动尝试配置)。"
