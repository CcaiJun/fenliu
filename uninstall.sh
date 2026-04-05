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
    python3 <<EOF
import re, os, shutil, subprocess, sys

nginx_conf = "$NGINX_CONF"
stream_conf = "$STREAM_CONF"
backup_conf = nginx_conf + ".bak_uninstall"

if not os.path.exists(backup_conf):
    shutil.copy2(nginx_conf, backup_conf)

with open(nginx_conf, 'r') as f:
    content = f.read()

# 移除 include 语句
content = re.sub(r'include\s+.*stream-sni\.conf\s*;', '', content)

# 检查是否遗留了由我们创建的空 stream 块 (仅包含 whitespace)
content = re.sub(r'stream\s*\{\s*\}', '', content)

with open(nginx_conf, 'w') as f:
    f.write(content)

# 如果规则文件存在，先将其重命名，以防止 include 报错测试 (如果上面没移除干净)
if os.path.exists(stream_conf):
    shutil.move(stream_conf, stream_conf + ".bak")

test_result = subprocess.run(['nginx', '-t'], capture_output=True, text=True)
if test_result.returncode != 0:
    shutil.copy2(backup_conf, nginx_conf)
    if os.path.exists(stream_conf + ".bak"):
        shutil.move(stream_conf + ".bak", stream_conf)
    print(f"Error: Nginx 卸载清理测试失败，已自动还原主配置。错误信息:\n{test_result.stderr}")
    sys.exit(1)

# 清理成功，删除多余的规则文件和临时备份
if os.path.exists(stream_conf + ".bak"):
    os.remove(stream_conf + ".bak")
os.remove(backup_conf)
EOF
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Nginx 关联已安全清理${PLAIN}"
    else
        echo -e "${RED}警告：Nginx 关联清理失败，请手动移除 include 配置${PLAIN}"
    fi
fi

# 3. 自动还原宝塔站点配置
BT_VHOST_DIR="/www/server/panel/vhost/nginx"
if [[ -d "$BT_VHOST_DIR" ]]; then
    echo -e "${YELLOW}正在检测并还原宝塔站点端口配置...${PLAIN}"
    python3 <<EOF
import os, re, shutil, subprocess

BT_VHOST_DIR = "$BT_VHOST_DIR"
reverted_count = 0

if os.path.exists(BT_VHOST_DIR):
    for filename in os.listdir(BT_VHOST_DIR):
        if filename.endswith(".conf"):
            conf_path = os.path.join(BT_VHOST_DIR, filename)
            backup_path = f"{conf_path}.bak"
            uninstall_bak = f"{conf_path}.bak_uninstall"
            
            try:
                # 记录卸载前状态以便回滚
                shutil.copy2(conf_path, uninstall_bak)
                
                # 优先从备份还原
                if os.path.exists(backup_path):
                    shutil.copy2(backup_path, conf_path)
                    
                    test_result = subprocess.run(['nginx', '-t'], capture_output=True, text=True)
                    if test_result.returncode != 0:
                        shutil.copy2(uninstall_bak, conf_path)
                        print(f"  - 警告: 从备份还原 {filename[:-5]} 导致 Nginx 测试失败，已放弃还原")
                    else:
                        print(f"  - 已从备份还原站点: {filename[:-5]}")
                        reverted_count += 1
                else:
                    with open(conf_path, 'r', encoding='utf-8') as f:
                        content = f.read()
                    
                    # 如果没有备份，尝试通过正则还原
                    if re.search(r'listen\s+(?!443)\d+\s+ssl\s*;', content):
                        new_content = re.sub(r'listen\s+\d+\s+ssl\s*;', 'listen 443 ssl;', content)
                        new_content = re.sub(r'listen\s+\[::\]:\d+\s+ssl\s*;', 'listen [::]:443 ssl;', new_content)
                        new_content = re.sub(r'if\s*\(\$server_port\s*!=\s*\d+\s*\)', 'if ($server_port != 443)', new_content)
                        new_content = re.sub(r'error_page\s+497\s+https://\$host(:\d+)?\$request_uri;', 'error_page 497 https://$host$request_uri;', new_content)
                        
                        if new_content != content:
                            with open(conf_path, 'w', encoding='utf-8') as f:
                                f.write(new_content)
                                
                            test_result = subprocess.run(['nginx', '-t'], capture_output=True, text=True)
                            if test_result.returncode != 0:
                                shutil.copy2(uninstall_bak, conf_path)
                                print(f"  - 警告: 正则还原 {filename[:-5]} 导致 Nginx 测试失败，已放弃还原")
                            else:
                                print(f"  - 已通过正则还原站点: {filename[:-5]}")
                                reverted_count += 1
                
                # 清理临时卸载备份
                if os.path.exists(uninstall_bak):
                    os.remove(uninstall_bak)
            except Exception as e:
                if os.path.exists(uninstall_bak):
                    shutil.copy2(uninstall_bak, conf_path)
                    os.remove(uninstall_bak)
                print(f"  - 处理 {filename} 时出错: {str(e)}")

if reverted_count > 0:
    print(f"成功还原了 {reverted_count} 个站点的配置。")
else:
    print("未发现需要还原的站点配置。")
EOF
    # 清理所有持久备份文件
    rm -f "$BT_VHOST_DIR"/*.conf.bak
fi

# 4. 尝试重载 Nginx 以恢复
echo -e "${YELLOW}正在尝试重载 Nginx...${PLAIN}"
nginx -t >/dev/null 2>&1
if [ $? -eq 0 ]; then
    systemctl reload nginx >/dev/null 2>&1 || nginx -s reload >/dev/null 2>&1
    echo -e "${GREEN}Nginx 已平滑重载并恢复正常${PLAIN}"
else
    echo -e "${RED}警告：Nginx 配置检查失败，请手动检查配置文件，未执行重载操作${PLAIN}"
fi

# 5. 提示

echo -e "\n${GREEN}卸载完成！${PLAIN}"
echo -e "您可以手动删除安装目录：${YELLOW}rm -rf $(pwd)${PLAIN}"
