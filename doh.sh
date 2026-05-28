#!/bin/bash
# ============================================================
# DoH 一键部署脚本 v2
# 覆盖：chinadns-ng + acme.sh(GoDaddy) + dnsproxy + nginx SNI分流
# 系统：Debian / Ubuntu (systemd, x86_64)
# 用法：bash deploy-doh.sh
# ============================================================

set -euo pipefail

# ── 颜色 ────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; PLAIN='\033[0m'

info()    { echo -e "${CYAN}[INFO]${PLAIN}  $*"; }
ok()      { echo -e "${GREEN}[OK]${PLAIN}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${PLAIN}  $*"; }
die()     {
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════╗${PLAIN}"
    echo -e "${RED}║  部署失败                                    ║${PLAIN}"
    echo -e "${RED}╠══════════════════════════════════════════════╣${PLAIN}"
    echo -e "${RED}║  原因：$*"
    echo -e "${RED}╚══════════════════════════════════════════════╝${PLAIN}"
    exit 1
}
section() { echo -e "\n${BOLD}${BLUE}━━━ $* ━━━${PLAIN}"; }

require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "请以 root 身份运行本脚本！"
}

assert() {
    local desc="$1"; shift
    if "$@" &>/dev/null; then
        ok "$desc"
    else
        die "$desc 测试失败\n║  命令：$*"
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

    # ★ 修复1：改为明文输入，不再隐藏
    read -rp "  GoDaddy API Secret                      : " GD_SECRET
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
    echo -e "  GoDaddy Secret  : ${GREEN}${GD_SECRET:0:4}******${PLAIN}"
    echo -e "  chinadns-ng 版本: ${GREEN}$CHINADNS_VER${PLAIN}"
    echo -e "  dnsproxy 版本   : ${GREEN}$DNSPROXY_VER${PLAIN}"
    echo ""
    read -rp "确认以上信息并开始部署？[y/N] " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || die "用户取消部署"

    CERT_CRT="/etc/ssl/certs/${DOMAIN}.crt"
    CERT_KEY="/etc/ssl/private/${DOMAIN}.key"
}

# ── 1. 安装基础依赖 ──────────────────────────────────────────
install_deps() {
    section "零、安装基础依赖"

    info "更新 apt 缓存..."
    apt-get update -qq || die "apt update 失败，检查网络或 sources.list"

    info "安装 dnsutils / curl / wget / nginx-stream..."
    apt-get install -y --no-install-recommends \
        dnsutils curl wget socat libnginx-mod-stream \
        || die "基础依赖安装失败"

    assert "dig  可用" which dig
    assert "curl 可用" which curl
    ok "基础依赖安装完成"
}

# ── 2. 安装 chinadns-ng ──────────────────────────────────────
install_chinadns() {
    section "一、安装 chinadns-ng"

    local url="https://github.com/zfl9/chinadns-ng/releases/download/${CHINADNS_VER}/chinadns-ng+wolfssl@x86_64-linux-musl@x86_64@fast+lto"

    # ★ 修复2：改用 curl，避免 wget -q --show-progress 卡住
    info "下载 chinadns-ng ${CHINADNS_VER}（curl）..."
    curl -fL --progress-bar -o /tmp/chinadns-ng "$url" \
        || die "下载 chinadns-ng 失败\n║  请手动检查版本号或访问：\n║  https://github.com/zfl9/chinadns-ng/releases"

    chmod +x /tmp/chinadns-ng
    mv /tmp/chinadns-ng /usr/local/bin/chinadns-ng
    assert "chinadns-ng 可执行" chinadns-ng -v

    info "下载域名列表（chnlist / gfwlist）..."
    mkdir -p /etc/chinadns
    curl -fL --progress-bar \
        -o /etc/chinadns/chnlist.txt \
        "https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt" \
        || die "下载 chnlist.txt 失败"
    curl -fL --progress-bar \
        -o /etc/chinadns/gfwlist.txt \
        "https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt" \
        || die "下载 gfwlist.txt 失败"

    assert "chnlist.txt 非空" test -s /etc/chinadns/chnlist.txt
    assert "gfwlist.txt 非空" test -s /etc/chinadns/gfwlist.txt

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
    for host in dot.pub dns.alidns.com; do
        for ip in $(dig +short "$host" 2>/dev/null | grep -E '^[0-9.]+$'); do
            echo "china-dns tls://${host}@${ip}#853" >> "$config"
        done
    done
    for host in dns.google cloudflare-dns.com dns.quad9.net; do
        for ip in $(dig +short "$host" 2>/dev/null | grep -E '^[0-9.]+$'); do
            echo "trust-dns tls://${host}@${ip}#853" >> "$config"
        done
    done

    info "配置预览："; grep -v '^#' "$config"

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

    dig @127.0.0.1 -p 5353 www.baidu.com +short +time=5 > /dev/null \
        && ok "baidu.com 解析测试通过" \
        || warn "baidu.com 解析测试失败（可能是 ipset 未就绪，通常不影响继续）"
    ok "chinadns-ng 安装完成"
}

# ── 3. 申请 SSL 证书 ─────────────────────────────────────────
install_cert() {
    section "二、申请 SSL 证书（acme.sh + GoDaddy DNS）"

    echo -e "${YELLOW}前置检查：请确认已在 GoDaddy DNS 中添加以下记录：${PLAIN}"
    echo -e "  类型: A  |  名称: *  |  值: 本服务器公网 IP"
    read -rp "  已添加，继续？[y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || die "请先添加 GoDaddy DNS 通配符 A 记录"

    # ★ 修复3：预先验证 GoDaddy API Key/Secret
    info "验证 GoDaddy API Key/Secret..."
    local gd_resp
    gd_resp=$(curl -sf -X GET \
        "https://api.godaddy.com/v1/domains/${DOMAIN}" \
        -H "Authorization: sso-key ${GD_KEY}:${GD_SECRET}" \
        -H "Accept: application/json" 2>&1) || true

    if echo "$gd_resp" | grep -q '"UNABLE_TO_AUTHENTICATE\|AUTHENTICATION_FAILED\|invalid\|Unauthorized'; then
        die "GoDaddy API 认证失败！\n║\n║  错误详情：$gd_resp\n║\n║  排查建议：\n║  1. 确认 Key/Secret 来自 https://developer.godaddy.com/keys/\n║  2. Environment 必须选 Production（不是 OTE 测试环境）\n║  3. 域名必须在该 GoDaddy 账户下\n║  4. GoDaddy 2023年起对小账户限制 API，需 10+ 个域名\n║     如受限，可改用 Cloudflare 托管 DNS"
    elif echo "$gd_resp" | grep -q '"domain"\|"domainId"'; then
        ok "GoDaddy API 验证通过，域名 ${DOMAIN} 可访问"
    else
        warn "GoDaddy API 返回未知响应，继续尝试..."
        warn "响应内容：$gd_resp"
    fi

    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        info "安装 acme.sh..."
        curl -fsSL https://get.acme.sh | sh -s email="admin@${DOMAIN}" \
            || die "acme.sh 安装失败"
    else
        ok "acme.sh 已存在，跳过安装"
    fi
    assert "acme.sh 可执行" test -x ~/.acme.sh/acme.sh

    info "申请通配符证书 *.${DOMAIN}..."
    export GD_Key="$GD_KEY"
    export GD_Secret="$GD_SECRET"
    if ! ~/.acme.sh/acme.sh --issue --dns dns_gd -d "*.${DOMAIN}"; then
        die "acme.sh 证书申请失败\n║\n║  常见原因：\n║  1. GoDaddy API 权限不足（小账户限制，需 10+ 域名）\n║  2. DNS 记录未生效，等几分钟后重试\n║  3. Key/Secret 填错（OTE vs Production）\n║\n║  调试命令（手动运行）：\n║  GD_Key=\"${GD_KEY}\" GD_Secret=\"${GD_SECRET}\" \\\n║    ~/.acme.sh/acme.sh --issue --dns dns_gd \\\n║    -d \"*.${DOMAIN}\" --debug 2"
    fi

    assert "证书文件已生成" eval "ls /root/.acme.sh/*.${DOMAIN}_ecc/*.${DOMAIN}.cer"

    info "安装证书到系统目录..."
    mkdir -p /etc/ssl/private /etc/ssl/certs
    ~/.acme.sh/acme.sh --install-cert -d "*.${DOMAIN}" \
        --key-file      "$CERT_KEY" \
        --fullchain-file "$CERT_CRT" \
        --reloadcmd "systemctl restart dnsproxy 2>/dev/null; systemctl restart nginx 2>/dev/null; true" \
        || die "install-cert 失败"

    assert "crt 文件存在" test -f "$CERT_CRT"
    assert "key 文件存在" test -f "$CERT_KEY"

    crontab -l 2>/dev/null | grep -q acme.sh \
        && ok "acme.sh 自动续签 crontab 已配置" \
        || warn "未找到 acme.sh crontab，建议手动检查"

    ok "SSL 证书申请完成"
}

# ── 4. 安装 dnsproxy ─────────────────────────────────────────
install_dnsproxy() {
    section "三、安装 dnsproxy"

    local ver="${DNSPROXY_VER}"
    local url="https://github.com/AdguardTeam/dnsproxy/releases/download/${ver}/dnsproxy-linux-amd64-${ver}.tar.gz"

    info "下载 dnsproxy ${ver}（curl）..."
    curl -fL --progress-bar -o /tmp/dnsproxy.tgz "$url" \
        || die "下载 dnsproxy 失败\n║  请检查版本号：https://github.com/AdguardTeam/dnsproxy/releases"

    tar -xzf /tmp/dnsproxy.tgz -C /tmp
    mv /tmp/linux-amd64/dnsproxy /usr/local/bin/dnsproxy
    chmod +x /usr/local/bin/dnsproxy
    rm -rf /tmp/dnsproxy.tgz /tmp/linux-amd64
    assert "dnsproxy 可执行" dnsproxy --version

    info "创建 dnsproxy systemd 服务（DoH:444 / DNS:53）..."
    tee /etc/systemd/system/dnsproxy.service > /dev/null <<EOF
[Unit]
Description=DNSProxy with DoH
After=network.target
[Service]
ExecStart=/usr/local/bin/dnsproxy \\
  --port=53 \\
  --https-port=444 \\
  --tls-crt="${CERT_CRT}" \\
  --tls-key="${CERT_KEY}" \\
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
    assert "端口 444 已监听"    sh -c "ss -ltnp | grep -q ':444'"
    assert "端口 53  已监听"    sh -c "ss -ltnp | grep -q ':53 '"

    dig @127.0.0.1 -p 53 www.google.com +short +time=5 > /dev/null \
        && ok "www.google.com 解析测试通过" \
        || warn "解析测试失败（检查 chinadns-ng 状态）"
    ok "dnsproxy 安装完成"
}

# ── 5. 修改本机 DNS ──────────────────────────────────────────
configure_local_dns() {
    section "四、配置本机 DNS → 127.0.0.1"

    chattr -i /etc/resolv.conf 2>/dev/null || true
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    assert "resolv.conf 内容正确" grep -q "127.0.0.1" /etc/resolv.conf

    dig www.google.com +short +time=5 > /dev/null \
        && ok "系统 DNS 解析测试通过" \
        || warn "解析失败，检查 dnsproxy / chinadns-ng"

    chattr +i /etc/resolv.conf
    ok "本机 DNS 配置完成并已锁定"
}

# ── 6. 配置 nginx SNI 分流 ───────────────────────────────────
configure_nginx() {
    section "五、nginx SNI 分流（443 → trojan:4444 / DoH:444）"

    assert "nginx 已安装" which nginx
    assert "trojan-go 监听 4444" sh -c "ss -ltnp | grep -q ':4444'" \
        || die "trojan-go 未在 4444 端口运行，请先配置 trojan-go 监听 4444"

    local NGINX_CONF="/etc/nginx/nginx.conf"

    if ! grep -q "ngx_stream_module" "$NGINX_CONF"; then
        sed -i '1iload_module modules/ngx_stream_module.so;' "$NGINX_CONF"
        ok "已添加 load_module stream"
    else
        ok "stream 模块已存在，跳过"
    fi

    if ! grep -q "stream.d" "$NGINX_CONF"; then
        sed -i '/^http {/i include /etc/nginx/stream.d/*.conf;' "$NGINX_CONF"
        ok "已添加 stream.d include"
    else
        ok "stream.d include 已存在，跳过"
    fi

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
    nginx -t || die "nginx 配置语法错误，请检查 /etc/nginx/stream.d/trojan.conf"
    systemctl restart nginx
    sleep 1
    assert "nginx 运行中"       systemctl is-active nginx
    assert "端口 443 已监听"    sh -c "ss -ltnp | grep -q ':443'"
    ok "nginx SNI 分流配置完成"
}

# ── 7. 最终验收 ──────────────────────────────────────────────
final_check() {
    section "最终验收"
    echo ""
    echo -e "${BOLD}端口状态：${PLAIN}"
    for port in 53 443 444 4444 5353; do
        if ss -ltnp 2>/dev/null | grep -q ":${port} "; then
            echo -e "  :${port}  ${GREEN}✓ 监听中${PLAIN}"
        else
            echo -e "  :${port}  ${RED}✗ 未监听${PLAIN}"
        fi
    done

    echo ""
    echo -e "${BOLD}服务状态：${PLAIN}"
    for svc in chinadns-ng dnsproxy nginx; do
        if systemctl is-active "$svc" &>/dev/null; then
            echo -e "  ${svc}: ${GREEN}✓ 运行中${PLAIN}"
        else
            echo -e "  ${svc}: ${RED}✗ 未运行${PLAIN}"
        fi
    done

    echo ""
    echo -e "${BOLD}Mac 测试命令（需 dig >= 9.17.10，可用 brew install bind）：${PLAIN}"
    echo -e "  ${CYAN}/opt/homebrew/bin/dig +https @${DOH_DOMAIN} baidu.com A${PLAIN}"
    echo -e "  ${CYAN}/opt/homebrew/bin/dig +https @${DOH_DOMAIN} google.com A${PLAIN}"
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e "${GREEN}  部署完成！${PLAIN}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e "  DoH 端点 : ${CYAN}https://${DOH_DOMAIN}/dns-query${PLAIN}"
    echo -e "  查看日志 : journalctl -u chinadns-ng -u dnsproxy -f"
}

# ── 主流程 ───────────────────────────────────────────────────
main() {
    require_root
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║   DoH 全栈一键部署脚本 v2                   ║"
    echo "║   chinadns-ng + acme.sh + dnsproxy + nginx  ║"
    echo "╚══════════════════════════════════════════════╝"
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
