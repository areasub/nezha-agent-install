#!/bin/sh

NZ_BASE_PATH="/opt/nezha"
NZ_AGENT_PATH="${NZ_BASE_PATH}/agent"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

err() {
    printf "${red}%s${plain}\n" "$*" >&2
}

success() {
    printf "${green}%s${plain}\n" "$*"
}

info() {
    printf "${yellow}%s${plain}\n" "$*"
}

sudo_cmd() {
    myEUID=$(id -ru)
    if [ "$myEUID" -ne 0 ]; then
        if command -v sudo > /dev/null 2>&1; then
            command sudo "$@"
        else
            err "ERROR: sudo is not installed on the system, the action cannot be proceeded."
            exit 1
        fi
    else
        "$@"
    fi
}

deps_check() {
    deps="wget unzip grep curl"
    for dep in $deps; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            err "$dep not found, please install it first."
            exit 1
        fi
    done
}

geo_check() {
    api_list="https://blog.cloudflare.com/cdn-cgi/trace https://developers.cloudflare.com/cdn-cgi/trace"
    ua="Mozilla/5.0"
    for url in $api_list; do
        text="$(curl -A "$ua" -m 10 -s "$url")"
        if echo "$text" | grep -qw 'CN'; then
            isCN=true
            break
        fi
    done
}

env_check() {
    mach=$(uname -m)
    case "$mach" in
        amd64|x86_64) os_arch="amd64" ;;
        i386|i686) os_arch="386" ;;
        aarch64|arm64) os_arch="arm64" ;;
        *arm*) os_arch="arm" ;;
        s390x) os_arch="s390x" ;;
        riscv64) os_arch="riscv64" ;;
        mips) os_arch="mips" ;;
        mipsel|mipsle) os_arch="mipsle" ;;
        *) err "Unknown architecture: $mach"; exit 1 ;;
    esac

    case "$(uname)" in
        *Linux*) os="linux" ;;
        *Darwin*) os="darwin" ;;
        *FreeBSD*) os="freebsd" ;;
        *) err "Unknown OS"; exit 1 ;;
    esac
}

prompt_config() {
    read -rp "是否使用非 root 用户安装？[Y/n]: " use_non_root
    use_non_root=${use_non_root:-Y}
    if [ "$use_non_root" != "${use_non_root#[Yy]}" ]; then
        read -rp "请输入用户名（默认 nezha）: " install_user
        install_user=${install_user:-nezha}
        if ! id "$install_user" >/dev/null 2>&1; then
            info "用户 $install_user 不存在，正在创建..."
            sudo_cmd useradd -m -s /bin/bash "$install_user"
        fi
        is_non_root=true
    else
        is_non_root=false
    fi

    read -rp "是否启用 TLS（加密连接）？[y/N]: " enable_tls
    enable_tls=${enable_tls:-N}
    if [ "$enable_tls" = "${enable_tls#[Nn]}" ]; then
        NZ_TLS="1"
    else
        NZ_TLS="0"
    fi

    read -rp "请输入服务端地址（格式：IP:端口）: " NZ_SERVER
    read -rp "请输入客户端密钥: " NZ_CLIENT_SECRET

    NZ_UUID=""
    NZ_DISABLE_AUTO_UPDATE=""
    NZ_DISABLE_FORCE_UPDATE=""
    NZ_DISABLE_COMMAND_EXECUTE=""
    NZ_SKIP_CONNECTION_COUNT=""
}

init() {
    deps_check
    env_check
    geo_check

    if [ -n "$isCN" ]; then
        CN=true
    fi

    if [ -z "$CN" ]; then
        GITHUB_URL="github.com"
    else
        GITHUB_URL="gitee.com"
    fi
}

download_agent() {
    info "正在下载 Nezha Agent..."
    if [ -z "$CN" ]; then
        NZ_AGENT_URL="https://${GITHUB_URL}/nezhahq/agent/releases/latest/download/nezha-agent_${os}_${os_arch}.zip"
    else
        _version=$(curl -m 10 -sL "https://gitee.com/api/v5/repos/naibahq/agent/releases/latest" | awk -F '"' '{for(i=1;i<=NF;i++){if($i=="tag_name"){print $(i+2)}}}')
        NZ_AGENT_URL="https://${GITHUB_URL}/naibahq/agent/releases/download/${_version}/nezha-agent_${os}_${os_arch}.zip"
    fi

    wget -T 60 -O /tmp/nezha-agent_${os}_${os_arch}.zip "$NZ_AGENT_URL" >/dev/null 2>&1 || {
        err "下载失败，请检查网络连接。"
        exit 1
    }
}

install_as_non_root() {
    user_home=$(eval echo "~$install_user")
    AGENT_DIR="$user_home/nezha"
    sudo_cmd -u "$install_user" mkdir -p "$AGENT_DIR"
    sudo_cmd unzip -qo /tmp/nezha-agent_${os}_${os_arch}.zip -d "$AGENT_DIR"
    sudo_cmd rm -f /tmp/nezha-agent_${os}_${os_arch}.zip

    TLS_OPTION=""
    [ "$NZ_TLS" = "1" ] && TLS_OPTION="-t"

    SERVICE_FILE="[Unit]
Description=Nezha Agent
After=network.target

[Service]
ExecStart=${AGENT_DIR}/nezha-agent -s ${NZ_SERVER} -p ${NZ_CLIENT_SECRET} ${TLS_OPTION}
Restart=always
RestartSec=3

[Install]
WantedBy=default.target"

    sudo_cmd -u "$install_user" mkdir -p "$user_home/.config/systemd/user"
    echo "$SERVICE_FILE" | sudo_cmd tee "$user_home/.config/systemd/user/nezha-agent.service" >/dev/null

    sudo_cmd loginctl enable-linger "$install_user"
    sudo_cmd -u "$install_user" systemctl --user daemon-reexec
    sudo_cmd -u "$install_user" systemctl --user daemon-reload
    sudo_cmd -u "$install_user" systemctl --user enable --now nezha-agent.service

    success "已使用 systemd --user 启动 nezha-agent，用户：$install_user"
}

install_as_root() {
    download_agent
    sudo_cmd mkdir -p "$NZ_AGENT_PATH"
    sudo_cmd unzip -qo /tmp/nezha-agent_${os}_${os_arch}.zip -d "$NZ_AGENT_PATH"
    sudo_cmd rm -f /tmp/nezha-agent_${os}_${os_arch}.zip

    config_path="$NZ_AGENT_PATH/config.yml"
    [ -f "$config_path" ] && config_path="$NZ_AGENT_PATH/config-$(date +%s).yml"

    env="NZ_UUID=$NZ_UUID NZ_SERVER=$NZ_SERVER NZ_CLIENT_SECRET=$NZ_CLIENT_SECRET NZ_TLS=$NZ_TLS NZ_DISABLE_AUTO_UPDATE=$NZ_DISABLE_AUTO_UPDATE NZ_DISABLE_FORCE_UPDATE=$NZ_DISABLE_FORCE_UPDATE NZ_DISABLE_COMMAND_EXECUTE=$NZ_DISABLE_COMMAND_EXECUTE NZ_SKIP_CONNECTION_COUNT=$NZ_SKIP_CONNECTION_COUNT"

    sudo_cmd "${NZ_AGENT_PATH}/nezha-agent" service -c "$config_path" uninstall >/dev/null 2>&1
    sudo_cmd env $env "${NZ_AGENT_PATH}/nezha-agent" service -c "$config_path" install || {
        err "安装服务失败"
        exit 1
    }

    success "nezha-agent 安装成功（以 root 启动）"
}

uninstall() {
    if [ -d "$NZ_AGENT_PATH" ]; then
        find "$NZ_AGENT_PATH" -type f -name "*config*.yml" | while read -r file; do
            sudo_cmd "$NZ_AGENT_PATH/nezha-agent" service -c "$file" uninstall
            sudo_cmd rm -f "$file"
        done
        info "已卸载 root 模式下的 nezha-agent"
    fi

    read -rp "是否还要删除非 root 用户的 systemd 服务？[y/N]: " del_user_service
    if [ "$del_user_service" = "${del_user_service#[Nn]}" ]; then
        read -rp "请输入用户（默认 nezha）: " user
        user=${user:-nezha}
        user_home=$(eval echo "~$user")
        sudo_cmd -u "$user" systemctl --user stop nezha-agent.service
        sudo_cmd -u "$user" systemctl --user disable nezha-agent.service
        sudo_cmd rm -f "$user_home/.config/systemd/user/nezha-agent.service"
        info "已卸载用户 $user 的 systemd 服务"
    fi
}

### 脚本入口 ###
if [ "$1" = "uninstall" ]; then
    uninstall
    exit
fi

init
prompt_config
download_agent

if [ "$is_non_root" = true ]; then
    install_as_non_root
else
    install_as_root
fi
