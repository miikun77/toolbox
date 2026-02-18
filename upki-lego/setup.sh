#!/bin/bash
# UPKI ACME + lego + systemd.timer セットアップスクリプト

set -euo pipefail

NGINX_BIN=$(command -v nginx || echo /usr/sbin/nginx)

SERVICE_FILE="/etc/systemd/system/lego-renew.service"
TIMER_FILE="/etc/systemd/system/lego-renew.timer"
WEBROOT="/var/www/acme"

# ============================================================
# 入力プロンプト
# ============================================================
echo "============================================"
echo " UPKI ACME + lego セットアップ"
echo "============================================"
echo ""
read -rp "KID          : " KID
read -rp "HMAC         : " HMAC
read -rp "ドメイン     : " DOMAIN
read -rp "メールアドレス: " EMAIL
echo ""

LEGO_PATH="/etc/lego/${DOMAIN}"
NGINX_CONF="/etc/nginx/conf.d/${DOMAIN}.conf"
CERT_FILE="${LEGO_PATH}/certificates/${DOMAIN}.crt"

# 初回かどうかチェック
IS_FIRST=true
[[ -f "${SERVICE_FILE}" ]] && IS_FIRST=false

# 確認
if $IS_FIRST; then
  echo ">>> 初回セットアップとして実行します"
else
  echo ">>> ${DOMAIN} を既存の設定に追加します"
fi
echo "    ドメイン : ${DOMAIN}"
echo "    メール   : ${EMAIL}"
echo ""
read -rp "続けますか？ [y/N]: " CONFIRM
[[ "${CONFIRM}" =~ ^[Yy]$ ]] || { echo "中断しました"; exit 1; }
echo ""

# ============================================================
# [1/5] ディレクトリの準備
# ============================================================
echo "==> [1/5] ディレクトリの準備"
sudo mkdir -p "${WEBROOT}" "${LEGO_PATH}"
sudo chmod 755 "${WEBROOT}"
sudo chmod 700 /etc/lego

# ============================================================
# [2/5] Nginx HTTP-01 チャレンジ設定
# ============================================================
echo "==> [2/5] Nginx HTTP-01 チャレンジ設定"
if [[ -f "${NGINX_CONF}" ]]; then
  echo "    既存ファイルがあるためスキップ: ${NGINX_CONF}"
else
  sudo tee "${NGINX_CONF}" > /dev/null <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        root ${WEBROOT};
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
  sudo "${NGINX_BIN}" -t && sudo systemctl reload nginx
fi

# ============================================================
# [3/5] 証明書の初回取得
# ============================================================
echo "==> [3/5] 証明書の取得"
if [[ -f "${CERT_FILE}" ]]; then
  echo "    証明書が既に存在するためスキップ: ${CERT_FILE}"
else
  sudo docker run --rm \
    -v /etc/lego/:/etc/lego \
    -v "${WEBROOT}:${WEBROOT}" \
    -v /etc/localtime:/etc/localtime:ro \
    -v /etc/timezone:/etc/timezone:ro \
    goacme/lego \
    --path "${LEGO_PATH}/" \
    --server https://secomtrust-acme.com/acme/ \
    --eab --kid "${KID}" --hmac "${HMAC}" \
    --domains "${DOMAIN}" \
    --key-type rsa2048 \
    --email "${EMAIL}" \
    --accept-tos \
    --http --http.webroot "${WEBROOT}" \
    run
fi

# ============================================================
# [4/5] Nginx SSL 設定
# ============================================================
echo "==> [4/5] Nginx SSL 設定"
if grep -q "listen 443" "${NGINX_CONF}" 2>/dev/null; then
  echo "    443 ブロックが既に存在するためスキップ"
else
  sudo tee -a "${NGINX_CONF}" > /dev/null <<EOF

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${DOMAIN};

    root /var/www/html;
    index index.html index.htm;

    ssl_certificate     ${LEGO_PATH}/certificates/${DOMAIN}.crt;
    ssl_certificate_key ${LEGO_PATH}/certificates/${DOMAIN}.key;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
  sudo "${NGINX_BIN}" -t && sudo systemctl reload nginx
fi

# ============================================================
# [5/5] systemd 設定
# ============================================================
echo "==> [5/5] systemd 設定"

if $IS_FIRST; then
  # 初回：service と timer を新規作成
  sudo tee "${SERVICE_FILE}" > /dev/null <<EOF
[Unit]
Description=lego renew and reload nginx
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/docker run --rm \\
  -v /etc/lego:/etc/lego \\
  -v ${WEBROOT}:${WEBROOT} \\
  -v /etc/localtime:/etc/localtime:ro \\
  -v /etc/timezone:/etc/timezone:ro \\
  goacme/lego \\
  --path ${LEGO_PATH}/ \\
  --server https://secomtrust-acme.com/acme/ \\
  --email ${EMAIL} \\
  --domains ${DOMAIN} \\
  --http --http.webroot ${WEBROOT} \\
  renew --days 30
ExecStartPost=${NGINX_BIN} -t
ExecStartPost=/bin/systemctl reload nginx
EOF

  sudo tee "${TIMER_FILE}" > /dev/null <<EOF
[Unit]
Description=Run lego renew daily

[Timer]
OnCalendar=*-*-* 04:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable lego-renew.timer
  sudo systemctl start lego-renew.timer
  echo "    timer を有効化しました"

else
  # 2つ目以降：既存 service の ExecStartPost 直前に ExecStart を挿入
  if sudo grep -qF "${DOMAIN}" "${SERVICE_FILE}"; then
    echo "    ${DOMAIN} は既に service に登録済みのためスキップ"
  else
    TMPBLOCK=$(mktemp)
    cat > "${TMPBLOCK}" <<EXECBLOCK
ExecStart=/usr/bin/docker run --rm \\
  -v /etc/lego:/etc/lego \\
  -v ${WEBROOT}:${WEBROOT} \\
  -v /etc/localtime:/etc/localtime:ro \\
  -v /etc/timezone:/etc/timezone:ro \\
  goacme/lego \\
  --path ${LEGO_PATH}/ \\
  --server https://secomtrust-acme.com/acme/ \\
  --email ${EMAIL} \\
  --domains ${DOMAIN} \\
  --http --http.webroot ${WEBROOT} \\
  renew --days 30
EXECBLOCK

    # 最初の ExecStartPost 行の直前に新しい ExecStart ブロックを挿入
    TMPSERVICE=$(mktemp)
    sudo cat "${SERVICE_FILE}" | awk -v f="${TMPBLOCK}" '
      /^ExecStartPost=/ && !done {
        while ((getline line < f) > 0) print line
        done = 1
      }
      { print }
    ' | sudo tee "${TMPSERVICE}" > /dev/null

    sudo cp "${TMPSERVICE}" "${SERVICE_FILE}"
    rm -f "${TMPBLOCK}" "${TMPSERVICE}"

    sudo systemctl daemon-reload
    echo "    ${DOMAIN} の ExecStart を service に追記しました"
  fi
fi

echo ""
echo "==> 完了！"
echo "    証明書 : ${CERT_FILE}"
echo "    ログ確認: sudo journalctl -u lego-renew"
