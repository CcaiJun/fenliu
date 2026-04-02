#!/bin/bash
# 运行前请确保安装了依赖：pip install -r requirements.txt
# 需要 root 权限运行，以便可以执行 nginx -s reload

if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 权限运行此脚本，否则可能无法重载 Nginx"
  echo "例如: sudo ./run.sh"
  exit
fi

python3 app.py
