#!/bin/bash

set -e

print_help() {
    echo "Nezha Agent 安装脚本"
    echo
    echo "用法："
    echo "  bash <(curl -Ls https://xxx/nezha-agent.sh) [选项]"
    echo
    echo "选项："
    echo "  install    安装并配置 Agent（默认）"
    echo "  uninstall  卸载 Agent"
    echo "  config     重新配置 Agent"
    echo "  help       显示帮助信息"
    echo
}

err() {
    echo -e "\033[31m[错误] $*\033[0m"
}

info() {
    echo -e "\033[32m[信息] $*\033[0m"
}

deps_check() {
    for dep in wget unzip grep curl jq; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            err "$dep 未安装，请先安装"
            exit 1
        fi
    done
}

geo_check() {
    isCN=false
    for url in https://blog.cloudflare.com/cdn-cgi/trace https://developers.cloudflare.com/cdn-cgi/trace; do
        if curl -s --max-time 10 "$url" | grep -q 'loc=CN'; then
            isCN=true
            break
        fi
    done
}

env_check() {
    case "$(uname -m)" in
        amd64|x86_64) os_arch="amd64" ;;
        i386|i686) os_arch="386" ;;
        aarch64|arm64) os_arch="arm64" ;;
        *arm*) os_arch="arm" ;;
        *) err "未知架构"; exit 1 ;;
    esac

    case "$(uname)" in
        Linux) os="linux" ;;
        *) err "仅支持 Linux"; exit 1 ;;
    esac
}

gh_proxy() {
    if $isCN; then
        echo "https://ghproxy.com/"
    else
        echo ""
    fi
}

install_agent() {
    deps_check
    geo_check
    env_check

    echo
    echo "[1/6] 选择安装模式"
    echo "1) 非 root 用户安装（推荐）"
    echo "2) root 用户安装"
    read -rp "请输入选项 [1]: " user_mode
    user_mode=${user_mode:-1}

    if [[ "$user_mode" == "1" ]]; then
        username="nezha"
        if ! id "$username" &>/dev/null; then
            echo "用户 $username 不存在，正在创建..."
            useradd -m "$username"
        fi
        run_as_user=true
    else
        username="root"
        run_as_user=false
    fi

    install_dir="/home/$username/nezha-agent"
    [[ "$username" == "root" ]] && install_dir="/root/nezha-agent"
    mkdir -p "$install_dir"
    chown "$username:$username" "$install_dir"

    echo
    echo "[2/6] 选择 Agent 版本（留空默认最新版）"
    latest_tag=$(curl -s "https://api.github.com/repos/naiba/nezha/releases/latest" | jq -r .tag_name)
    echo "可用版本：$latest_tag"
    read -rp "输入版本号 [默认：$latest_tag]: " version
    version=${version:-$latest_tag}

    echo
    echo "[3/6] 下载 Nezha Agent..."
    proxy=$(gh_proxy)
    agent_url="${proxy}https://github.com/naiba/nezha/releases/download/${version}/nezha-agent-${os}-${os_arch}.zip"
    tmp_dir=$(mktemp -d)
    wget -qO "$tmp_dir/agent.zip" "$agent_url" || { err "下载失败"; exit 1; }
    unzip -q "$tmp_dir/agent.zip" -d "$tmp_dir/"
    mv "$tmp_dir/nezha-agent" "$install_dir/"
    chmod +x "$install_dir/nezha-agent"
    chown "$username:$username" "$install_dir/nezha-agent"
    rm -rf "$tmp_dir"

    echo
    echo "[4/6] 配置服务器信息"
    read -rp "请输入服务端地址 (格式 example.com:5555): " server_addr
    read -rp "请输入客户端密钥 (UUID): " secret
    read -rp "是否启用 TLS？(1=否, 2=是) [默认2]: " use_tls
    use_tls=${use_tls:-2}

    config_file="/home/$username/nezha-agent.conf"
    [[ "$username" == "root" ]] && config_file="/root/nezha-agent.conf"
    cat > "$config_file" <<EOF
{
  "server": "$server_addr",
  "tls": $([[ "$use_tls" == "2" ]] && echo true || echo false),
  "client_secret": "$secret"
}
EOF
    chown "$username:$username" "$config_file"

    echo
    echo "[5/6] 创建 systemd 服务"
    cat > /etc/systemd/system/nezha-agent.service <<EOF
[Unit]
Description=Nezha Agent (${username})
After=network.target

[Service]
Type=simple
User=$username
WorkingDirectory=$install_dir
ExecStart=$install_dir/nezha-agent --config $config_file
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    echo
    echo "[6/6] 启动并设置开机自启"
    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable --now nezha-agent.service

    echo
    echo "✅ 安装完成，当前运行状态如下："
    systemctl status nezha-agent.service --no-pager
}

uninstall_agent() {
    echo "正在卸载 Nezha Agent..."
    systemctl disable --now nezha-agent.service 2>/dev/null || true
    rm -f /etc/systemd/system/nezha-agent.service
    systemctl daemon-reload
    echo "如需手动清理，请删除 ~/nezha-agent 及配置文件"
    echo "卸载完成"
}

reconfig_agent() {
    echo "重新配置 Nezha Agent..."
    read -rp "请输入运行该 Agent 的用户名（默认 nezha）: " username
    username=${username:-nezha}
    [[ ! -d "/home/$username" && "$username" != "root" ]] && err "无效用户" && exit 1

    config_file="/home/$username/nezha-agent.conf"
    [[ "$username" == "root" ]] && config_file="/root/nezha-agent.conf"

    read -rp "服务器地址（格式 example.com:5555）: " server_addr
    read -rp "客户端密钥（UUID）: " secret
    read -rp "是否启用 TLS？(1=否, 2=是) [默认2]: " use_tls
    use_tls=${use_tls:-2}

    cat > "$config_file" <<EOF
{
  "server": "$server_addr",
  "tls": $([[ "$use_tls" == "2" ]] && echo true || echo false),
  "client_secret": "$secret"
}
EOF
    chown "$username:$username" "$config_file"

    systemctl restart nezha-agent.service
    echo "重新配置完成 ✅"
}

main() {
    case "$1" in
        uninstall) uninstall_agent ;;
        config) reconfig_agent ;;
        help) print_help ;;
        *) install_agent ;;
    esac
}

main "$1"
