#!/bin/bash
# ============================================================
# DoH 一键部署脚本
# 覆盖：chinadns-ng + acme.sh(GoDaddy) + dnsproxy + nginx SNI分流
# 系统：Debian / Ubuntu (systemd, x86_64)
# 用法：bash deploy-doh.sh
# ============================================================

set -euo pipefail

# ── 颜色 ────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; PLAIN='\033[0m'

# ── 工具函数 ─────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${PLAIN}  $*"; }
ok()      { echo -e "${GREEN}[OK]${PLAIN}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${PLAIN}  $*"; }
die()     { echo -e "${RED}[FAIL]${PLAIN}  $*" >&2; echo -e "${RED}>>> 部署中止，请修复上述问题后重新运行。${PLAIN}" >&2; exit 1; }
section() { echo -e "\n${BOLD}${BLUE}━━━ $* ━━━${PLAIN}"; }

require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "请以 root 身份运行本脚本！"
}

# 测试函数：失败时打印提示并退出
assert() {
    local desc="$1"; shift
    if "$@" &>/dev/null; then
        ok "$desc"
    else
        die "$desc —— 测试失败，命令：$*"
    fi
}

# ── 0. 收集输入 ──────────────────────────────────────────────
collect_inputs() {
    section "配置信息收集"
    echo -e "${YELLOW}请依次输入以下信息（直接回车使用默认值）${PLAIN}\n"

    read -rp "  域名 (如 example.com)                  : " DOMAIN
    [[ -z "$DOMAIN" ]] && die "域名不能为空"

    read -rp "  DoH 子域名前缀 (如 doh，完整为 doh.$DOMAIN) : " DOH_SUB
    [[ -z "$DOH_SUB" ]] && die "DoH 子域名前缀不能为空"
    DOH_DOMAIN="${DOH_SUB}.${DOMAIN}"

    read -rp "  GoDaddy API Key                         : " GD_KEY
    [[ -z "$GD_KEY" ]] && die "GoDaddy Key 不能为空"

    read -rsp "  GoDaddy API Secret                      : " GD_SECRET
    echo
    [[ -z "$GD_SECRET" ]] && die "GoDaddy Secret 不能为空"

    read -rp "  chinadns-ng 版本日期 [默认: 2025.08.09] : " CHINADNS_VER
    CHINADNS_VER="${CHINADNS_VER:-2025.08.09}"

    read -rp "  dnsproxy 版本号    [默认: v0.76.1]      : " DNSPROXY_VER
    DNSPROXY_VER="${DNSPROXY_VER:-v0.76.1}"

    echo ""
    echo -e "${BOLD}── 确认配置 ────────────────────────────────${PLAIN}"
    echo -e "  主域名          : ${GREEN}$DOMAIN${PLAIN}"
    echo -e "  DoH 域名        : ${GREEN}$DOH_DOMAIN${PLAIN}"
    echo -e "  GoDaddy Key     : ${GREEN}${GD_KEY:0:6}******${PLAIN}"
    echo -e "  chinadns-ng 版本: ${GREEN}$CHINADNS_VER${PLAIN}"
    echo -e "  dnsproxy 版本   : ${GREEN}$DNSPROXY_VER${PLAIN}"
    echo ""
    read -rp "确认以上信息并开始部署？[y/N] " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || die "用户取消部署"

    # 证书路径（acme.sh 默认路径）
    CERT_DIR="/root/.acme.sh/*.${DOMAIN}_ecc"
    CERT_FILE="${CERT_DIR}/*.${DOMAIN}.cer"
    KEY_FILE="${CERT_DIR}/*.${DOMAIN}.key"
}

# ── 1. 安装基础依赖 ──────────────────────────────────────────
install_deps() {
    section "零、安装基础依赖"

    info "更新 apt 缓存..."
    apt-get update -qq || die "apt update 失败"

    info "安装 dnsutils (dig)..."
    apt-get install -y --no-install-recommends dnsutils curl wget socat libnginx-mod-stream \
        || die "基础依赖安装失败"

    assert "dig 可用" which dig
    assert "curl 可用" which curl
    assert "wget 可用" which wget
    ok "基础依赖安装完成"
}

# ── 2. 安装 chinadns-ng ──────────────────────────────────────
install_chinadns() {
    section "一、安装 chinadns-ng"

    local url="https://github.com/zfl9/chinadns-ng/releases/download/${CHINADNS_VER}/chinadns-ng+wolfssl@x86_64-linux-musl@x86_64@fast+lto"

    info "下载 chinadns-ng ${CHINADNS_VER}..."
    wget -q --show-progress -O /tmp/chinadns-ng "$url" \
        || die "下载 chinadns-ng 失败，请检查版本号或网络：$url"
    chmod +x /tmp/chinadns-ng
    mv /tmp/chinadns-ng /usr/local/bin/chinadns-ng
    assert "chinadns-ng 可执行" chinadns-ng -v

    info "下载域名列表..."
    mkdir -p /etc/chinadns
    wget -q --show-progress -O /etc/chinadns/chnlist.txt \
        "https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt" \
        || die "下载 chnlist.txt 失败"
    wget -q --show-progress -O /etc/chinadns/gfwlist.txt \
        "https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt" \
        || die "下载 gfwlist.txt 失败"
    assert "chnlist.txt 存在且非空" test -s /etc/chinadns/chnlist.txt
    assert "gfwlist.txt 存在且非空" test -s /etc/chinadns/gfwlist.txt

    info "生成 chinadns-ng 配置..."
    local config="/etc/chinadns-ng.conf"
    cat > "$config" <<EOF
# ChinaDNS-NG 配置文件（自动生成）
bind-addr 0.0.0.0
bind-port 5353
chnlist-file /etc/chinadns/chnlist.txt
gfwlist-file /etc/chinadns/gfwlist.txt
add-tagchn-ip chnip,chnip6
add-taggfw-ip gfwip,gfwip6
ipset-name4 chnroute
ipset-name6 chnroute6
cache 4096
cache-stale 86400
cache-refresh 20
verdict-cache 4096
EOF
    # 追加 china-dns（解析域名后拼 TLS upstream）
    for host in dot.pub dns.alidns.com; do
        for ip in $(dig +short "$host" 2>/dev/null | grep -E '^[0-9.]+$'); do
            echo "china-dns tls://${host}@${ip}#853" >> "$config"
        done
    done
    # 追加 trust-dns
    for host in dns.google cloudflare-dns.com dns.quad9.net; do
        for ip in $(dig +short "$host" 2>/dev/null | grep -E '^[0-9.]+$'); do
            echo "trust-dns tls://${host}@${ip}#853" >> "$config"
        done
    done
    assert "配置文件存在" test -f "$config"
    info "配置预览："; grep -v '^#' "$config" | head -20

    info "创建 systemd 服务..."
    tee /etc/systemd/system/chinadns-ng.service > /dev/null <<'EOF'
[Unit]
Description=ChinaDNS-NG Service
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/chinadns-ng -C /etc/chinadns-ng.conf
Restart=on-failure
RestartSec=5s
User=root
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable chinadns-ng
    systemctl restart chinadns-ng
    sleep 2

    assert "chinadns-ng 服务运行中" systemctl is-active chinadns-ng
    assert "chinadns-ng 监听 5353" sh -c "ss -ltnp | grep -q ':5353'"

    info "DNS 解析测试..."
    dig @127.0.0.1 -p 5353 www.baidu.com +short +time=5 > /dev/null \
        || warn "baidu.com 解析测试失败（可能正常，继续）"
    dig @127.0.0.1 -p 5353 www.google.com +short +time=5 > /dev/null \
        || warn "google.com 解析测试失败（可能正常，继续）"
    ok "chinadns-ng 安装完成"
}

# ── 3. 申请 SSL 证书 ─────────────────────────────────────────
install_cert() {
    section "二、申请 SSL 证书（acme.sh + GoDaddy DNS）"

    echo -e "${YELLOW}前置检查：请确认已在 GoDaddy 域名 DNS 中添加以下记录：${PLAIN}"
    echo -e "  类型: A  |  名称: *  |  值: 本服务器公网 IP"
    read -rp "  已添加，继续？[y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || die "请先添加 GoDaddy DNS 通配符 A 记录"

    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        info "安装 acme.sh..."
        curl -fsSL https://get.acme.sh | sh -s email="admin@${DOMAIN}" \
            || die "acme.sh 安装失败"
    else
        ok "acme.sh 已存在，跳过安装"
    fi
    assert "acme.sh 可执行" test -x ~/.acme.sh/acme.sh

    info "申请通配符证书 *.${DOMAIN}（通过 GoDaddy DNS 验证）..."
    export GD_Key="$GD_KEY"
    export GD_Secret="$GD_SECRET"
    ~/.acme.sh/acme.sh --issue --dns dns_gd -d "*.${DOMAIN}" \
        || die "SSL 证书申请失败，请检查 GoDaddy Key/Secret 及域名 DNS 记录"

    assert "证书文件存在" eval "test -f ${CERT_FILE}"
    assert "私钥文件存在" eval "test -f ${KEY_FILE}"

    info "设置证书自动续签 reload 钩子..."
    ~/.acme.sh/acme.sh --install-cert -d "*.${DOMAIN}" \
        --key-file   "/etc/ssl/private/${DOMAIN}.key" \
        --fullchain-file "/etc/ssl/certs/${DOMAIN}.crt" \
        --reloadcmd  "systemctl restart dnsproxy 2>/dev/null; systemctl restart nginx 2>/dev/null; true" \
        || die "install-cert 失败"

    assert "crt 文件存在" test -f "/etc/ssl/certs/${DOMAIN}.crt"
    assert "key 文件存在" test -f "/etc/ssl/private/${DOMAIN}.key"

    info "验证 crontab 续签任务..."
    crontab -l 2>/dev/null | grep -q acme.sh \
        && ok "acme.sh crontab 已配置" \
        || warn "未找到 acme.sh crontab，建议手动检查"

    ok "SSL 证书申请完成"
}

# ── 4. 安装 dnsproxy ─────────────────────────────────────────
install_dnsproxy() {
    section "三、安装 dnsproxy"

    local ver="${DNSPROXY_VER}"
    local url="https://github.com/AdguardTeam/dnsproxy/releases/download/${ver}/dnsproxy-linux-amd64-${ver}.tar.gz"

    info "下载 dnsproxy ${ver}..."
    wget -q --show-progress -O /tmp/dnsproxy.tgz "$url" \
        || die "下载 dnsproxy 失败：$url"
    tar -xzf /tmp/dnsproxy.tgz -C /tmp
    mv /tmp/linux-amd64/dnsproxy /usr/local/bin/dnsproxy
    chmod +x /usr/local/bin/dnsproxy
    rm -rf /tmp/dnsproxy.tgz /tmp/linux-amd64
    assert "dnsproxy 可执行" dnsproxy --version

    info "创建 dnsproxy systemd 服务（DoH 端口 444，DNS 端口 53）..."
    tee /etc/systemd/system/dnsproxy.service > /dev/null <<EOF
[Unit]
Description=DNSProxy with DoH
After=network.target
[Service]
ExecStart=/usr/local/bin/dnsproxy \\
  --port=53 \\
  --https-port=444 \\
  --tls-crt="/etc/ssl/certs/${DOMAIN}.crt" \\
  --tls-key="/etc/ssl/private/${DOMAIN}.key" \\
  --upstream=127.0.0.1:5353
Restart=always
RestartSec=5
LimitNOFILE=1048576
User=root
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable dnsproxy
    systemctl restart dnsproxy
    sleep 2

    assert "dnsproxy 服务运行中" systemctl is-active dnsproxy
    assert "端口 444 已监听" sh -c "ss -ltnp | grep -q ':444'"
    assert "端口 53  已监听" sh -c "ss -ltnp | grep -q ':53 '"

    info "本地 DNS 解析测试（通过 dnsproxy）..."
    dig @127.0.0.1 -p 53 www.google.com +short +time=5 > /dev/null \
        || warn "www.google.com 解析测试失败（检查 chinadns-ng 是否正常）"
    ok "dnsproxy 安装完成"
}

# ── 5. 修改本机 DNS ──────────────────────────────────────────
configure_local_dns() {
    section "四、配置本机 DNS → 127.0.0.1"

    info "移除 resolv.conf 不可变属性（如有）..."
    chattr -i /etc/resolv.conf 2>/dev/null || true

    info "写入 nameserver 127.0.0.1..."
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    assert "resolv.conf 内容正确" grep -q "127.0.0.1" /etc/resolv.conf

    info "测试系统 DNS 解析..."
    dig www.google.com +short +time=5 > /dev/null \
        || warn "www.google.com 解析失败（请检查 dnsproxy/chinadns-ng）"

    info "锁定 resolv.conf（chattr +i）..."
    chattr +i /etc/resolv.conf
    ok "本机 DNS 配置完成"
}

# ── 6. 配置 nginx SNI 分流 ───────────────────────────────────
configure_nginx() {
    section "五、nginx SNI 分流（443 → trojan:4444 / DoH:444）"

    assert "nginx 已安装" which nginx
    assert "trojan-go 监听 4444" sh -c "ss -ltnp | grep -q ':4444'"

    local NGINX_CONF="/etc/nginx/nginx.conf"

    info "注入 stream 模块到 nginx.conf..."
    if ! grep -q "ngx_stream_module" "$NGINX_CONF"; then
        sed -i '1iload_module modules/ngx_stream_module.so;' "$NGINX_CONF"
        ok "已添加 load_module"
    else
        ok "stream 模块已存在，跳过"
    fi

    if ! grep -q "stream.d" "$NGINX_CONF"; then
        sed -i '/^http {/i include /etc/nginx/stream.d/*.conf;' "$NGINX_CONF"
        ok "已添加 stream.d include"
    else
        ok "stream.d include 已存在，跳过"
    fi

    info "生成 stream 分流配置..."
    mkdir -p /etc/nginx/stream.d
    cat > /etc/nginx/stream.d/trojan.conf <<EOF
stream {
    map \$ssl_preread_server_name \$backend_name {
        ${DOH_DOMAIN}  doh;
        default        trojan;
    }

    upstream trojan {
        server 127.0.0.1:4444;
    }
    upstream doh {
        server 127.0.0.1:444;
    }

    server {
        listen 443 reuseport;
        listen [::]:443 reuseport;
        ssl_preread on;
        proxy_pass \$backend_name;
    }
}
EOF
    assert "nginx 配置语法正确" nginx -t
    systemctl restart nginx
    sleep 1
    assert "nginx 服务运行中" systemctl is-active nginx
    assert "端口 443 已监听" sh -c "ss -ltnp | grep -q ':443'"

    ok "nginx SNI 分流配置完成"
}

# ── 7. 最终验收测试 ──────────────────────────────────────────
final_check() {
    section "最终验收"
    echo ""
    echo -e "${BOLD}端口检查：${PLAIN}"
    for port in 53 443 444 4444 5353; do
        if ss -ltnp | grep -q ":${port} "; then
            echo -e "  端口 ${port}: ${GREEN}✓ 监听中${PLAIN}"
        else
            echo -e "  端口 ${port}: ${RED}✗ 未监听${PLAIN}"
        fi
    done

    echo ""
    echo -e "${BOLD}服务状态：${PLAIN}"
    for svc in chinadns-ng dnsproxy nginx; do
        if systemctl is-active "$svc" &>/dev/null; then
            echo -e "  $svc: ${GREEN}✓ 运行中${PLAIN}"
        else
            echo -e "  $svc: ${RED}✗ 未运行${PLAIN}"
        fi
    done

    echo ""
    echo -e "${BOLD}DoH 测试命令（在 Mac 上运行）：${PLAIN}"
    echo -e "  ${CYAN}/opt/homebrew/bin/dig +https @${DOH_DOMAIN} baidu.com A${PLAIN}"
    echo -e "  ${CYAN}/opt/homebrew/bin/dig +https @${DOH_DOMAIN} google.com A${PLAIN}"
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e "${GREEN}  部署完成！${PLAIN}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e "  主域名   : $DOMAIN"
    echo -e "  DoH 端点 : https://${DOH_DOMAIN}/dns-query"
    echo -e "  日志查看 : journalctl -u chinadns-ng -u dnsproxy -f"
}

# ── 主流程 ───────────────────────────────────────────────────
main() {
    require_root
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════╗"
    echo "║     DoH 全栈一键部署脚本                ║"
    echo "║  chinadns-ng + acme.sh + dnsproxy + nginx ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${PLAIN}"

    collect_inputs
    install_deps
    install_chinadns
    install_cert
    install_dnsproxy
    configure_local_dns
    configure_nginx
    final_check
}

main "$@"
