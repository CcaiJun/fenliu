import os
import json
import uuid
import subprocess
import re
from flask import Flask, request, jsonify, render_template

app = Flask(__name__)
DATA_FILE = "data.json"
NGINX_CONF_FILE = "/www/server/nginx/conf/stream-sni.conf"
BT_VHOST_DIR = "/www/server/panel/vhost/nginx/"

def patch_bt_site_config(domain, target_port):
    """尝试自动修改宝塔站点的 Nginx 配置文件端口"""
    conf_path = os.path.join(BT_VHOST_DIR, f"{domain}.conf")
    if not os.path.exists(conf_path):
        return False, f"未找到宝塔配置文件: {conf_path}"
    
    # 备份原配置
    backup_path = f"{conf_path}.bak"
    try:
        import shutil
        if not os.path.exists(backup_path):
            shutil.copy2(conf_path, backup_path)
            
        with open(conf_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        # 1. 修改 listen 443 ssl 为 target_port
        # 增强正则，支持 IPv6 和更多格式
        new_content = re.sub(r'listen\s+443\s+ssl\s*;', f'listen {target_port} ssl;', content)
        new_content = re.sub(r'listen\s+\[::\]:443\s+ssl\s*;', f'listen [::]:{target_port} ssl;', new_content)
        
        # 2. 修改 if ($server_port != 443) 为 target_port
        new_content = re.sub(r'if\s*\(\$server_port\s*!=\s*443\s*\)', f'if ($server_port != {target_port})', new_content)
        
        # 3. 修改 error_page 497 https://$host$request_uri; -> https://$host:target_port$request_uri;
        # 移除已存在的端口后再添加，防止重复叠加
        new_content = re.sub(r'error_page\s+497\s+https://\$host(:\d+)?\$request_uri;', f'error_page 497 https://$host:{target_port}$request_uri;', new_content)

        if new_content == content:
            # 即使没变也可能已经改过了，返回成功
            return True, f"配置文件已是目标状态: {conf_path}"

        with open(conf_path, 'w', encoding='utf-8') as f:
            f.write(new_content)
            
        # 验证 Nginx 配置
        test_result = subprocess.run(['nginx', '-t'], capture_output=True, text=True)
        if test_result.returncode != 0:
            # 还原备份
            shutil.copy2(backup_path, conf_path)
            return False, f"Nginx 配置测试失败，已还原: {test_result.stderr}"
            
        return True, f"成功修改宝塔配置文件: {conf_path}"
    except Exception as e:
        return False, f"修改配置文件时出错: {str(e)}"

@app.route('/api/bt_sites', methods=['GET'])
def get_bt_sites():
    """扫描宝塔站点的 Nginx 配置文件，提取域名和端口"""
    sites = []
    if not os.path.exists(BT_VHOST_DIR):
        return jsonify(sites)
    
    for filename in os.listdir(BT_VHOST_DIR):
        if filename.endswith(".conf"):
            domain = filename[:-5]
            conf_path = os.path.join(BT_VHOST_DIR, filename)
            try:
                with open(conf_path, 'r', encoding='utf-8') as f:
                    content = f.read()
                
                # 提取监听端口
                listen_ports = re.findall(r'listen\s+(\d+)\s*(?:ssl|;)', content)
                # 排除 80 端口，重点看 443 或已修改过的端口
                ports = [p for p in listen_ports if p != '80']
                
                if ports:
                    sites.append({
                        "domain": domain,
                        "ports": list(set(ports))
                    })
            except Exception:
                continue
    return jsonify(sites)

@app.route('/')
def index():
    return render_template('index.html')

def load_data():
    if not os.path.exists(DATA_FILE):
        return {"listen_port": 443, "routes": [], "default_backend_server": "127.0.0.1:4433"}
    with open(DATA_FILE, 'r', encoding='utf-8') as f:
        data = json.load(f)
        if "default_backend_server" not in data:
            data["default_backend_server"] = "127.0.0.1:4433"
        return data

def save_data(data):
    with open(DATA_FILE, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2)

def generate_nginx_config(data):
    routes = data.get("routes", [])
    listen_port = data.get("listen_port", 443)
    default_backend_server = data.get("default_backend_server", "127.0.0.1:4433")
    
    config = []
    config.append("    # 由 SNI 管理面板自动生成")
    config.append("    map $ssl_preread_server_name $backend_name {")
    for r in routes:
        config.append(f"        {r['domain']}    {r['backend_name']};")
    config.append(f"        default          default_backend;")
    config.append("    }")
    config.append("")
    
    for r in routes:
        config.append(f"    upstream {r['backend_name']} {{")
        config.append(f"        server {r['backend_server']};")
        config.append("    }")
        config.append("")
    
    config.append(f"    upstream default_backend {{")
    config.append(f"        server {default_backend_server};")
    config.append("    }")
    config.append("")
        
    config.append("    server {")
    config.append(f"        listen {listen_port} reuseport;")
    config.append("        proxy_pass $backend_name;")
    config.append("        ssl_preread on;")
    config.append("    }")
    
    with open(NGINX_CONF_FILE, 'w', encoding='utf-8') as f:
        f.write("\n".join(config))

@app.route('/api/data', methods=['GET'])
def get_data():
    return jsonify(load_data())

@app.route('/api/routes', methods=['POST'])
def add_route():
    req = request.json
    domain = req.get('domain', '').strip()
    backend_server = str(req.get('backend_server', '')).replace(' ', '')
    auto_patch = req.get('auto_patch', False)
    
    if not domain or not backend_server:
        return jsonify({"error": "域名和后端地址不能为空"}), 400
        
    # 自动补全 127.0.0.1:
    if ':' not in str(backend_server):
        backend_server = f"127.0.0.1:{backend_server}"
    elif not backend_server.startswith('127.0.0.1:'):
        # 如果填了别的 IP，也允许，但如果不带 IP 只带冒号（如 :10001），则补全
        if backend_server.startswith(':'):
            backend_server = f"127.0.0.1{backend_server}"
        
    backend_name = req.get('backend_name')
    if not backend_name:
        # 生成一个安全的后端名称 (仅允许字母、数字和下划线)
        backend_name = re.sub(r'[^a-zA-Z0-9_]', '_', domain) + "_backend"
        
    data = load_data()
    # 检查域名是否已存在
    if any(r['domain'] == domain for r in data['routes']):
        return jsonify({"error": "该域名已存在"}), 400
        
    # 自动修改宝塔配置
    patch_msg = ""
    if auto_patch:
        # 获取后端端口
        try:
            target_port = backend_server.split(':')[-1]
            success, msg = patch_bt_site_config(domain, target_port)
            patch_msg = msg
        except Exception as e:
            patch_msg = f"无法提取端口或修改失败: {str(e)}"

    new_route = {
        "id": str(uuid.uuid4())[:8],
        "domain": domain,
        "backend_name": backend_name,
        "backend_server": backend_server
    }
    
    data['routes'].append(new_route)
    save_data(data)
    generate_nginx_config(data)
    
    return jsonify({"message": f"添加成功. {patch_msg}", "route": new_route})

@app.route('/api/routes/<route_id>', methods=['PUT'])
def update_route(route_id):
    req = request.json
    domain = req.get('domain', '').strip()
    backend_server = str(req.get('backend_server', '')).replace(' ', '')
    auto_patch = req.get('auto_patch', False)
    
    if not domain or not backend_server:
        return jsonify({"error": "域名和后端地址不能为空"}), 400
        
    # 自动补全 127.0.0.1:
    if ':' not in str(backend_server):
        backend_server = f"127.0.0.1:{backend_server}"
    elif not backend_server.startswith('127.0.0.1:'):
        if backend_server.startswith(':'):
            backend_server = f"127.0.0.1{backend_server}"
            
    data = load_data()
    route_index = -1
    for i, r in enumerate(data['routes']):
        if r['id'] == route_id:
            route_index = i
            break
            
    if route_index == -1:
        return jsonify({"error": "未找到该规则"}), 404
        
    # 自动修改宝塔配置
    patch_msg = ""
    if auto_patch:
        try:
            target_port = backend_server.split(':')[-1]
            success, msg = patch_bt_site_config(domain, target_port)
            patch_msg = msg
        except Exception as e:
            patch_msg = f"无法提取端口或修改失败: {str(e)}"

    data['routes'][route_index]['domain'] = domain
    data['routes'][route_index]['backend_server'] = backend_server
    if req.get('backend_name'):
        data['routes'][route_index]['backend_name'] = req.get('backend_name')
    
    save_data(data)
    generate_nginx_config(data)
    return jsonify({"message": f"修改成功. {patch_msg}"})

@app.route('/api/routes/<route_id>', methods=['DELETE'])
def delete_route(route_id):
    data = load_data()
    initial_length = len(data['routes'])
    data['routes'] = [r for r in data['routes'] if r['id'] != route_id]
    
    if len(data['routes']) == initial_length:
        return jsonify({"error": "未找到该规则"}), 404
        
    save_data(data)
    generate_nginx_config(data)
    return jsonify({"message": "删除成功"})

@app.route('/api/settings', methods=['POST'])
def update_settings():
    req = request.json
    listen_port = req.get('listen_port')
    default_backend_server = req.get('default_backend_server')
    
    data = load_data()
    if listen_port:
        data['listen_port'] = int(listen_port)
    if default_backend_server:
        # 补全 127.0.0.1:
        if ':' not in str(default_backend_server):
            default_backend_server = f"127.0.0.1:{default_backend_server}"
        elif default_backend_server.startswith(':'):
            default_backend_server = f"127.0.0.1{default_backend_server}"
        data['default_backend_server'] = default_backend_server
        
    save_data(data)
    generate_nginx_config(data)
    return jsonify({"message": "设置已更新"})

@app.route('/api/migrate_all_bt', methods=['POST'])
def migrate_all_bt():
    """一键将所有未被分流规则占用的宝塔站点，其 443 端口修改为默认后端端口"""
    data = load_data()
    default_port = data.get("default_backend_server", "127.0.0.1:4433").split(':')[-1]
    
    if not os.path.exists(BT_VHOST_DIR):
        return jsonify({"error": "未找到宝塔 Nginx 配置目录"}), 404
    
    results = []
    routes_domains = [r['domain'] for r in data.get('routes', [])]
    
    for filename in os.listdir(BT_VHOST_DIR):
        if filename.endswith(".conf"):
            domain = filename[:-5]
            if domain in routes_domains:
                continue # 已在分流规则中，跳过
                
            success, msg = patch_bt_site_config(domain, default_port)
            results.append({"domain": domain, "success": success, "message": msg})
            
    return jsonify({"message": "批量迁移完成", "results": results})

@app.route('/api/restore_bt/<domain>', methods=['POST'])
def restore_bt_site(domain):
    """还原宝塔站点的 Nginx 配置文件端口"""
    conf_path = os.path.join(BT_VHOST_DIR, f"{domain}.conf")
    backup_path = f"{conf_path}.bak"
    
    if not os.path.exists(backup_path):
        # 如果没有备份文件，尝试通过正则强制改回 443
        try:
            with open(conf_path, 'r', encoding='utf-8') as f:
                content = f.read()
            
            new_content = re.sub(r'listen\s+\d+\s+ssl\s*;', 'listen 443 ssl;', content)
            new_content = re.sub(r'listen\s+\[::\]:\d+\s+ssl\s*;', 'listen [::]:443 ssl;', new_content)
            new_content = re.sub(r'if\s*\(\$server_port\s*!=\s*\d+\s*\)', 'if ($server_port != 443)', new_content)
            new_content = re.sub(r'error_page\s+497\s+https://\$host(:\d+)?\$request_uri;', 'error_page 497 https://$host$request_uri;', new_content)
            
            if new_content != content:
                with open(conf_path, 'w', encoding='utf-8') as f:
                    f.write(new_content)
                return jsonify({"message": "成功强制还原宝塔配置到 443"})
            return jsonify({"message": "配置似乎已经是 443 端口"})
        except Exception as e:
            return jsonify({"error": f"强制还原失败: {str(e)}"}), 500
            
    try:
        import shutil
        shutil.copy2(backup_path, conf_path)
        return jsonify({"message": f"成功从备份还原: {domain}"})
    except Exception as e:
        return jsonify({"error": f"从备份还原失败: {str(e)}"}), 500

@app.route('/api/apply', methods=['POST'])
def apply_config():
    try:
        # 先测试配置文件
        test_result = subprocess.run(['nginx', '-t'], capture_output=True, text=True)
        if test_result.returncode != 0:
            return jsonify({"error": "Nginx 配置测试失败", "details": test_result.stderr}), 500
            
        # 重载配置文件
        reload_result = subprocess.run(['nginx', '-s', 'reload'], capture_output=True, text=True)
        if reload_result.returncode != 0:
            return jsonify({"error": "Nginx 重载失败", "details": reload_result.stderr}), 500
            
        return jsonify({"message": "Nginx 配置已应用并重载成功"})
    except Exception as e:
        return jsonify({"error": f"执行命令时发生错误: {str(e)}\n(可能未安装 Nginx 或权限不足)"}), 500

if __name__ == '__main__':
    # 启动时先生成一次配置
    data = load_data()
    generate_nginx_config(data)
    panel_port = data.get('panel_port', 5000)
    app.run(host='0.0.0.0', port=panel_port, debug=True)
