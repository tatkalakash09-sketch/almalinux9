#!/bin/bash
# ============================================================
# 3proxy-0.9.5 IPv6 proxy factory
# AlmaLinux 9 / Rocky 9 / RHEL 9
# ============================================================
set -euo pipefail

# ---------- helpers ---------------------------------------------------------
random() { tr </dev/urandom -dc A-Za-z0-9 | head -c5; echo; }

hex4() {
    local arr=( {0..9} {a..f} )
    printf "%s%s%s%s" "${arr[RANDOM%16]}" "${arr[RANDOM%16]}" \
                     "${arr[RANDOM%16]}" "${arr[RANDOM%16]}"
}

gen64() { echo "$1:$(hex4):$(hex4):$(hex4):$(hex4)"; }

# ---------- install build deps & 3proxy -------------------------------------
echo "==> Installing build tools"
dnf install -y gcc make libarchive bsdtar curl zip iproute >/dev/null

echo "==> Downloading & building 3proxy-0.9.5"
cd /tmp
curl -sL https://github.com/z3APA3A/3proxy/archive/refs/tags/0.9.5.tar.gz | bsdtar -xzf -
cd 3proxy-0.9.5
make -f Makefile.Linux
mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
cp src/3proxy /usr/local/etc/3proxy/bin/
cd ..
rm -rf 3proxy-0.9.5

# ---------- prepare workspace -----------------------------------------------
WORKDIR="/home/proxy-095"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -d: -f1-4)

echo "IPv4=$IP4   IPv6-prefix=$IP6"
read -rp "How many proxies to create? " COUNT

FIRST_PORT=10000
LAST_PORT=$(( FIRST_PORT + COUNT - 1 ))

# ---------- generate per-proxy data -----------------------------------------
seq "$FIRST_PORT" "$LAST_PORT" | while read -r p; do
    printf "usr%s/pass%s/%s/%s/%s\n" "$(random)" "$(random)" "$IP4" "$p" "$(gen64 "$IP6")"
done >data.txt

# ---------- create runtime scripts ------------------------------------------
awk -F/ '{print "iptables -I INPUT -p tcp --dport "$4" -m conntrack --ctstate NEW -j ACCEPT"}' \
    data.txt >boot-iptables.sh
awk -F/ '{print "ip -6 addr add "$5"/64 dev eth0"}' \
    data.txt >boot-ip6.sh
chmod +x boot-*.sh

# ---------- 3proxy.cfg -------------------------------------------------------
awk -F/ 'BEGIN{printf "daemon\nmaxconn 1000\nnscache 65536\nsetgid 65535\nsetuid 65535\nflush\nauth strong\n"} \
         {printf "users %s:CL:%s\n", $1, $2}' data.txt >3proxy.cfg

awk -F/ '{printf "allow %s\nproxy -6 -n -a -p%s -i%s -e%s\nflush\n", $1, $4, $3, $5}' \
    data.txt >>3proxy.cfg

mv 3proxy.cfg /usr/local/etc/3proxy/

# ---------- systemd services ------------------------------------------------
cat >/etc/systemd/system/3proxy.service <<'EOF'
[Unit]
Description=3proxy IPv6 proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStart=/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
Restart=on-failure
LimitNOFILE=10048

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/proxy-init.service <<'EOF'
[Unit]
Description=Add IPv6 addresses & iptables rules for 3proxy
After=network-online.target
Before=3proxy.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/home/proxy-095/boot-iptables.sh
ExecStart=/home/proxy-095/boot-ip6.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now proxy-init.service 3proxy.service

# ---------- user-friendly list & upload -------------------------------------
awk -F/ '{print $3":"$4":"$1":"$2}' data.txt >proxy.txt
PASS=$(random)
zip -q --password "$PASS" proxy095.zip proxy.txt
URL=$(curl -s --upload-file proxy095.zip https://bashupload.com/proxy095.zip)

echo
echo "========== DONE =========="
echo "Download: $URL"
echo "ZIP password: $PASS"
echo "Format: IP:PORT:LOGIN:PASS"
