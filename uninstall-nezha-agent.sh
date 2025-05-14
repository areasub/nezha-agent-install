#!/bin/bash

echo "=== 卸载哪吒 Agent 脚本（非 root 用户安装）==="

# 询问用户名（默认 nezha）
read -rp "请输入安装时使用的用户名（默认：nezha）: " username
username=${username:-nezha}

# 检查是否存在该用户
if id "$username" &>/dev/null; then
    echo "[1/4] 停止并禁用 systemd 服务..."
    systemctl stop nezha-agent.service
    systemctl disable nezha-agent.service

    echo "[2/4] 删除 systemd 服务文件..."
    rm -f /etc/systemd/system/nezha-agent.service
    systemctl daemon-reload
    systemctl reset-failed

    echo "[3/4] 删除用户及其主目录（/home/$username）..."
    userdel -r "$username"

    echo "[4/4] 清理完成 ✅"
    echo "哪吒 Agent 已彻底卸载。"
else
    echo "⚠️ 用户 $username 不存在，似乎未安装或已被删除。"
fi
