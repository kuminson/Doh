#!/bin/bash
# ============================================================
# DoH 全栈部署脚本 v3
# 功能：部署 / 查看状态 / 卸载复原
# 覆盖：chinadns-ng + acme.sh(GoDaddy) + dnsproxy + nginx SNI分流
# 系统：Debian / Ubuntu (systemd, x86_64)
# 用法：bash deploy-doh.sh
# ============================================================

set -euo pipefail

# ── 颜色 ─────────────────────────────────────────────────────
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

require_root() { [[ "$(id -u)" -eq 0 ]] || die "请以 root 身份运行本脚本！"; }

assert() {
    local desc="$1"; shift
    if "$@" &>/dev/null; then ok "$desc"
    else die "$desc 测试失败\n║  命令：$*"; fi
}

# ── 主菜单 ────────────────────────────────────────────────────
main_menu() {
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║   DoH 全栈管理脚本 v3                       ║"
    echo "║   chinadns-ng + acme.sh + dnsproxy + nginx  ║"
    echo "╠══════════════════════════════════════════════╣"
    echo "║   1. 完整部署                               ║"
    echo "║   2. 查看当前 DoH 状态                      ║"
    echo "║   3. 卸载并复原                             ║"
    echo "║   0. 退出                                   ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${PLAIN}"
    read -rp "请选择操作 [0-3]: " choice
    case "$choice" in
        1) collect_inputs && run_deploy ;;
        2) show_status ;;
        3) run_uninstall ;;
        0) echo "退出。"; exit 0 ;;
        *) echo -e "${RED}无效选项${PLAIN}"; main_menu ;;
    esac
}

# ════════════════════════════════════════════════════════════
# ★ 功能一：查看当前 DoH 状态
# ════════════════════════════════════════════════════════════
show_status() {
    section "当前 DoH 状态总览"

    # ── 服务状态 ─────────────────────────────────────────────
    echo -e "\n${BOLD}▌ 服务状态${PLAIN}"
    for svc in chinadns-ng dnsproxy nginx; do
        if ! systemctl list-unit-files "${svc}.service" &>/dev/null; then
            echo -e "  ${svc}: ${YELLOW}未安装${PLAIN}"
        elif systemctl is-active "$svc" &>/dev/null; then
            local since
            since=$(systemctl show "$svc" -p ActiveEnterTimestamp --value 2>/dev/null || echo "未知")
            echo -e "  ${svc}: ${GREEN}✓ 运行中${PLAIN}  (启动于 $since)"
        else
            echo -e "  ${svc}: ${RED}✗ 未运行${PLAIN}"
            echo -e "       最近日志: $(journalctl -u "$svc" -n 3 --no-pager -q 2>/dev/null | tail -1)"
        fi
    done

    # ── 端口监听 ─────────────────────────────────────────────
    echo -e "\n${BOLD}▌ 端口监听${PLAIN}"
    for port in 53 443 444 4444 5353; do
        local proc
        proc=$(ss -ltnp 2>/dev/null | awk -v p=":${port} " '$0 ~ p {match($0,/users:\(\("([^"]+)/,a); print a[1]}' | head -1)
        if [[ -n "$proc" ]]; then
            echo -e "  :${port}  ${GREEN}✓ 监听中${PLAIN}  ($proc)"
        else
            echo -e "  :${port}  ${RED}✗ 未监听${PLAIN}"
        fi
    done

    # ── 证书信息 ─────────────────────────────────────────────
    echo -e "\n${BOLD}▌ SSL 证书${PLAIN}"
    local cert_found=false
    for crt in /etc/ssl/certs/*.crt; do
        [[ -f "$crt" ]] || continue
        cert_found=true
        local domain expiry now remaining
        domain=$(openssl x509 -noout -subject -in "$crt" 2>/dev/null | sed 's/.*CN=//' | sed 's/,.*//')
        expiry=$(openssl x509 -noout -enddate -in "$crt" 2>/dev/null | cut -d= -f2)
        now=$(date +%s)
        exp_ts=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
        remaining=$(( (exp_ts - now) / 86400 ))
        if [[ $remaining -gt 30 ]]; then
            echo -e "  ${crt##*/}: ${GREEN}✓ 有效${PLAIN}  (域名: $domain, 到期: $expiry, 剩余 ${remaining} 天)"
        elif [[ $remaining -gt 0 ]]; then
            echo -e "  ${crt##*/}: ${YELLOW}⚠ 即将到期${PLAIN}  (剩余 ${remaining} 天)"
        else
            echo -e "  ${crt##*/}: ${RED}✗ 已过期${PLAIN}  ($expiry)"
        fi
    done
    $cert_found || echo -e "  ${YELLOW}未找到 /etc/ssl/certs/*.crt${PLAIN}"

    # ── acme.sh 续签计划 ─────────────────────────────────────
    echo -e "\n${BOLD}▌ acme.sh 自动续签${PLAIN}"
    if crontab -l 2>/dev/null | grep -q acme.sh; then
        local cron_line
        cron_line=$(crontab -l 2>/dev/null | grep acme.sh | head -1)
        echo -e "  ${GREEN}✓ 已配置${PLAIN}  $cron_line"
    else
        echo -e "  ${YELLOW}未配置 crontab${PLAIN}"
    fi

    # ── 配置文件摘要 ─────────────────────────────────────────
    echo -e "\n${BOLD}▌ 配置文件${PLAIN}"
    local files=(
        "/etc/chinadns-ng.conf"
        "/etc/nginx/stream.d/trojan.conf"
        "/etc/systemd/system/chinadns-ng.service"
        "/etc/systemd/system/dnsproxy.service"
    )
    for f in "${files[@]}"; do
        if [[ -f "$f" ]]; then
            echo -e "  ${GREEN}✓${PLAIN} $f"
        else
            echo -e "  ${RED}✗${PLAIN} $f  ${YELLOW}(不存在)${PLAIN}"
        fi
    done

    # ── resolv.conf ──────────────────────────────────────────
    echo -e "\n${BOLD}▌ 本机 DNS (/etc/resolv.conf)${PLAIN}"
    local immutable=""
    lsattr /etc/resolv.conf 2>/dev/null | grep -q '\-i-' && immutable=" ${CYAN}[已锁定]${PLAIN}"
    echo -e "  $(cat /etc/resolv.conf 2>/dev/null)${immutable}"

    # ── DNS 解析测试 ─────────────────────────────────────────
    echo -e "\n${BOLD}▌ DNS 解析测试${PLAIN}"
    for host in www.baidu.com www.google.com; do
        local result
        result=$(dig @127.0.0.1 -p 5353 "$host" +short +time=3 2>/dev/null | head -1)
        if [[ -n "$result" ]]; then
            echo -e "  ${host}: ${GREEN}✓${PLAIN}  → $result"
        else
            echo -e "  ${host}: ${RED}✗ 无响应${PLAIN}"
        fi
    done

    # ── DoH 端点提示 ─────────────────────────────────────────
    echo -e "\n${BOLD}▌ DoH 测试命令（Mac 本地运行）${PLAIN}"
    local doh_domain=""
    if [[ -f /etc/nginx/stream.d/trojan.conf ]]; then
        doh_domain=$(grep -oP '^\s+\K\S+(?=\s+doh;)' /etc/nginx/stream.d/trojan.conf 2>/dev/null | head -1)
    fi
    if [[ -n "$doh_domain" ]]; then
        echo -e "  ${CYAN}/opt/homebrew/bin/dig +https @${doh_domain} baidu.com A${PLAIN}"
        echo -e "  ${CYAN}/opt/homebrew/bin/dig +https @${doh_domain} google.com A${PLAIN}"
    else
        echo -e "  ${YELLOW}未找到 DoH 域名配置，请检查 nginx stream 配置${PLAIN}"
    fi
    echo ""
}

# ════════════════════════════════════════════════════════════
# ★ 功能二：卸载并复原
# ════════════════════════════════════════════════════════════
run_uninstall() {
    section "卸载并复原"
    echo -e "${YELLOW}将要执行以下操作：${PLAIN}"
    echo "  • 停止并删除 chinadns-ng、dnsproxy 服务"
    echo "  • 删除二进制文件和配置文件"
    echo "  • 移除 nginx stream 分流配置，恢复 nginx.conf"
    echo "  • 解锁 resolv.conf，恢复为 8.8.8.8"
    echo "  • (可选) 删除 acme.sh 和 SSL 证书"
    echo "  ✗ 不会删除 trojan-go"
    echo ""
    read -rp "确认执行卸载？[y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || { echo "已取消"; return; }

    # ── 停止并禁用服务 ───────────────────────────────────────
    section "停止服务"
    for svc in chinadns-ng dnsproxy; do
        if systemctl list-unit-files "${svc}.service" &>/dev/null 2>&1; then
            systemctl stop "$svc"   2>/dev/null && ok "已停止 $svc" || warn "$svc 停止失败（可能未运行）"
            systemctl disable "$svc" 2>/dev/null && ok "已禁用 $svc" || true
            rm -f "/etc/systemd/system/${svc}.service"
            ok "已删除 ${svc}.service"
        else
            warn "$svc 服务不存在，跳过"
        fi
    done
    systemctl daemon-reload

    # ── 删除二进制 ───────────────────────────────────────────
    section "删除二进制文件"
    for bin in /usr/local/bin/chinadns-ng /usr/local/bin/dnsproxy; do
        if [[ -f "$bin" ]]; then
            rm -f "$bin" && ok "已删除 $bin"
        else
            warn "$bin 不存在，跳过"
        fi
    done

    # ── 删除配置目录 ─────────────────────────────────────────
    section "删除配置文件"
    rm -f /etc/chinadns-ng.conf  && ok "已删除 /etc/chinadns-ng.conf"
    rm -rf /etc/chinadns          && ok "已删除 /etc/chinadns/"

    # ── 复原 nginx ───────────────────────────────────────────
    section "复原 nginx 配置"
    local NGINX_CONF="/etc/nginx/nginx.conf"

    if [[ -f /etc/nginx/stream.d/trojan.conf ]]; then
        rm -f /etc/nginx/stream.d/trojan.conf && ok "已删除 stream.d/trojan.conf"
    fi
    # 如果 stream.d 目录为空则删除
    rmdir /etc/nginx/stream.d 2>/dev/null && ok "已删除空目录 stream.d" || true

    if grep -q "ngx_stream_module" "$NGINX_CONF" 2>/dev/null; then
        sed -i '/load_module modules\/ngx_stream_module.so;/d' "$NGINX_CONF"
        ok "已移除 nginx.conf 中的 load_module stream"
    fi
    if grep -q "stream.d" "$NGINX_CONF" 2>/dev/null; then
        sed -i '/include \/etc\/nginx\/stream.d/d' "$NGINX_CONF"
        ok "已移除 nginx.conf 中的 stream.d include"
    fi

    if nginx -t &>/dev/null; then
        systemctl restart nginx && ok "nginx 已重启"
    else
        warn "nginx 配置检测失败，请手动检查 $NGINX_CONF"
    fi

    # ── 复原 resolv.conf ─────────────────────────────────────
    section "复原本机 DNS"
    chattr -i /etc/resolv.conf 2>/dev/null || true
    echo -e "nameserver 8.8.8.8\nnameserver 8.8.4.4" > /etc/resolv.conf
    ok "resolv.conf 已恢复为 8.8.8.8 / 8.8.4.4"

    # ── 可选：删除证书和 acme.sh ─────────────────────────────
    section "SSL 证书 / acme.sh（可选）"
    read -rp "是否同时删除 acme.sh 和 SSL 证书？[y/N] " del_cert
    if [[ "$del_cert" =~ ^[Yy]$ ]]; then
        if [[ -f ~/.acme.sh/acme.sh ]]; then
            ~/.acme.sh/acme.sh --uninstall 2>/dev/null || true
            rm -rf ~/.acme.sh && ok "已删除 acme.sh"
        fi
        rm -f /etc/ssl/certs/*.crt /etc/ssl/private/*.key
        ok "已删除 /etc/ssl/ 下的证书和密钥"
    else
        warn "跳过证书删除，证书仍保留在 /etc/ssl/"
    fi

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e "${GREEN}  卸载完成，系统已复原${PLAIN}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e "  DNS      : 8.8.8.8 / 8.8.4.4"
    echo -e "  nginx    : stream 配置已移除，服务已重启"
    echo -e "  trojan-go: ${CYAN}未改动${PLAIN}"
    echo ""
}

# ════════════════════════════════════════════════════════════
# 功能三：完整部署（原有逻辑）
# ════════════════════════════════════════════════════════════
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
    echo -e "  chinadns-ng 版本: ${GREEN}$CHINADNS_VER${PLAIN}"
    echo -e "  dnsproxy 版本   : ${GREEN}$DNSPROXY_VER${PLAIN}"
    echo ""
    read -rp "确认以上信息并开始部署？[y/N] " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || die "用户取消部署"

    CERT_CRT="/etc/ssl/certs/${DOMAIN}.crt"
    CERT_KEY="/etc/ssl/private/${DOMAIN}.key"
}

run_deploy() {
    install_deps
    install_chinadns
    install_cert
    install_dnsproxy
    configure_local_dns
    configure_nginx
    final_check
}

install_deps() {
    section "零、安装基础依赖"
    apt-get update -qq || die "apt update 失败"
    apt-get install -y --no-install-recommends \
        dnsutils curl wget socat libnginx-mod-stream \
        || die "基础依赖安装失败"
    assert "dig  可用" which dig
    assert "curl 可用" which curl
    ok "基础依赖安装完成"
}

install_chinadns() {
    section "一、安装 chinadns-ng"
    local url="https://github.com/zfl9/chinadns-ng/releases/download/${CHINADNS_VER}/chinadns-ng+wolfssl@x86_64-linux-musl@x86_64@fast+lto"
    info "下载 chinadns-ng ${CHINADNS_VER}..."
    curl -g -fL --progress-bar --max-time 120 -o /tmp/chinadns-ng "$url" \
        || die "下载失败，请检查版本号：https://github.com/zfl9/chinadns-ng/releases"
    chmod +x /tmp/chinadns-ng
    mv /tmp/chinadns-ng /usr/local/bin/chinadns-ng
    assert "chinadns-ng 可执行" chinadns-ng -v

    info "下载域名列表..."
    mkdir -p /etc/chinadns
    curl -fL --progress-bar -o /etc/chinadns/chnlist.txt \
        "https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt" \
        || die "下载 chnlist.txt 失败"
    curl -fL --progress-bar -o /etc/chinadns/gfwlist.txt \
        "https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt" \
        || die "下载 gfwlist.txt 失败"
    assert "chnlist.txt 非空" test -s /etc/chinadns/chnlist.txt
    assert "gfwlist.txt 非空" test -s /etc/chinadns/gfwlist.txt

    info "生成配置..."
    local config="/etc/chinadns-ng.conf"
    cat > "$config" <<EOF
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
    assert "chinadns-ng 运行中"  systemctl is-active chinadns-ng
    assert "端口 5353 监听中" sh -c "ss -ltnp | grep -q ':5353'"
    ok "chinadns-ng 安装完成"
}

install_cert() {
    section "二、申请 SSL 证书（acme.sh + GoDaddy）"
    echo -e "${YELLOW}请确认已在 GoDaddy DNS 添加：A 记录  *  →  服务器公网 IP${PLAIN}"
    read -rp "  已添加，继续？[y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || die "请先添加 GoDaddy 通配符 A 记录"

    info "验证 GoDaddy API..."
    local gd_resp
    gd_resp=$(curl -sf -X GET \
        "https://api.godaddy.com/v1/domains/${DOMAIN}" \
        -H "Authorization: sso-key ${GD_KEY}:${GD_SECRET}" \
        -H "Accept: application/json" 2>&1) || true
    if echo "$gd_resp" | grep -qiE 'UNABLE_TO_AUTHENTICATE|AUTHENTICATION_FAILED|Unauthorized'; then
        die "GoDaddy API 认证失败\n║  错误：$gd_resp\n║  请确认 Key/Secret 来自 Production 环境（非 OTE）"
    fi
    ok "GoDaddy API 验证通过"

    [[ -f ~/.acme.sh/acme.sh ]] || {
        info "安装 acme.sh..."
        curl -fsSL https://get.acme.sh | sh -s email="admin@${DOMAIN}" || die "acme.sh 安装失败"
    }
    assert "acme.sh 可执行" test -x ~/.acme.sh/acme.sh

    export GD_Key="$GD_KEY"
    export GD_Secret="$GD_SECRET"
    ~/.acme.sh/acme.sh --issue --dns dns_gd -d "*.${DOMAIN}" \
        || die "证书申请失败\n║  建议：GD_Key=\"...\" GD_Secret=\"...\" ~/.acme.sh/acme.sh --issue --dns dns_gd -d \"*.${DOMAIN}\" --debug 2"

    mkdir -p /etc/ssl/private /etc/ssl/certs
    ~/.acme.sh/acme.sh --install-cert -d "*.${DOMAIN}" \
        --key-file      "$CERT_KEY" \
        --fullchain-file "$CERT_CRT" \
        --reloadcmd "systemctl restart dnsproxy 2>/dev/null; systemctl restart nginx 2>/dev/null; true" \
        || die "install-cert 失败"

    assert "crt 存在" test -f "$CERT_CRT"
    assert "key 存在" test -f "$CERT_KEY"
    ok "SSL 证书申请完成"
}

install_dnsproxy() {
    section "三、安装 dnsproxy"
    local url="https://github.com/AdguardTeam/dnsproxy/releases/download/${DNSPROXY_VER}/dnsproxy-linux-amd64-${DNSPROXY_VER}.tar.gz"
    info "下载 dnsproxy ${DNSPROXY_VER}..."
    curl -fL --progress-bar -o /tmp/dnsproxy.tgz "$url" \
        || die "下载失败：$url"
    tar -xzf /tmp/dnsproxy.tgz -C /tmp
    mv /tmp/linux-amd64/dnsproxy /usr/local/bin/dnsproxy
    chmod +x /usr/local/bin/dnsproxy
    rm -rf /tmp/dnsproxy.tgz /tmp/linux-amd64
    assert "dnsproxy 可执行" dnsproxy --version

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
    assert "dnsproxy 运行中"  systemctl is-active dnsproxy
    assert "端口 444 监听中" sh -c "ss -ltnp | grep -q ':444'"
    assert "端口 53  监听中" sh -c "ss -ltnp | grep -q ':53 '"
    ok "dnsproxy 安装完成"
}

configure_local_dns() {
    section "四、配置本机 DNS"
    chattr -i /etc/resolv.conf 2>/dev/null || true
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    assert "resolv.conf 正确" grep -q "127.0.0.1" /etc/resolv.conf
    chattr +i /etc/resolv.conf
    ok "本机 DNS 已指向 127.0.0.1 并锁定"
}

configure_nginx() {
    section "五、nginx SNI 分流"
    assert "nginx 已安装" which nginx
    ss -ltnp | grep -q ':4444' || die "trojan-go 未在 4444 端口运行，请先配置"

    local NGINX_CONF="/etc/nginx/nginx.conf"
    grep -q "ngx_stream_module" "$NGINX_CONF" \
        || sed -i '1iload_module modules/ngx_stream_module.so;' "$NGINX_CONF"
    grep -q "stream.d" "$NGINX_CONF" \
        || sed -i '/^http {/i include /etc/nginx/stream.d/*.conf;' "$NGINX_CONF"

    mkdir -p /etc/nginx/stream.d
    cat > /etc/nginx/stream.d/trojan.conf <<EOF
stream {
    map \$ssl_preread_server_name \$backend_name {
        ${DOH_DOMAIN}  doh;
        default        trojan;
    }
    upstream trojan { server 127.0.0.1:4444; }
    upstream doh    { server 127.0.0.1:444;  }
    server {
        listen 443 reuseport;
        listen [::]:443 reuseport;
        ssl_preread on;
        proxy_pass \$backend_name;
    }
}
EOF
    nginx -t || die "nginx 配置语法错误"
    systemctl restart nginx
    sleep 1
    assert "nginx 运行中"     systemctl is-active nginx
    assert "端口 443 监听中" sh -c "ss -ltnp | grep -q ':443'"
    ok "nginx SNI 分流配置完成"
}

final_check() {
    section "部署完成 — 最终验收"
    show_status
}

# ── 入口 ─────────────────────────────────────────────────────
require_root
main_menu
