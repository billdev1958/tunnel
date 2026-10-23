#!/usr/bin/env bash
# Instala y configura un Cloudflare Tunnel para ax01.com.mx
# Uso: sudo ./install.sh [nombre-del-tunel]
set -euo pipefail

TUNNEL_NAME="${1:-ax01}"
DOMAIN="ax01.com.mx"
HOSTNAMES=("cms.ax01.com.mx" "api.ax01.com.mx" "admin.ax01.com.mx")   # deben coincidir con el ingress de config.yml
CONF_DIR="/etc/cloudflared"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "Ejecuta como root: sudo $0" >&2
  exit 1
fi

# 1. Instalar cloudflared
if ! command -v cloudflared >/dev/null 2>&1; then
  echo ">> Instalando cloudflared..."
  if command -v apt-get >/dev/null 2>&1; then
    mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
      -o /usr/share/keyrings/cloudflare-main.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
      > /etc/apt/sources.list.d/cloudflared.list
    apt-get update && apt-get install -y cloudflared
  elif command -v dnf >/dev/null 2>&1; then
    curl -fsSL https://pkg.cloudflare.com/cloudflared.repo \
      -o /etc/yum.repos.d/cloudflared.repo
    dnf install -y cloudflared
  else
    curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
      -o /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared
  fi
fi
cloudflared --version

# 2. Autenticar con Cloudflare (abre/imprime URL; elige la zona ax01.com.mx)
if [[ ! -f "$HOME/.cloudflared/cert.pem" ]]; then
  echo ">> Autenticando. Abre la URL que aparece y selecciona ${DOMAIN}..."
  cloudflared tunnel login
fi

# 3. Crear el túnel (o reutilizar si ya existe)
if cloudflared tunnel info "$TUNNEL_NAME" >/dev/null 2>&1; then
  echo ">> El túnel '$TUNNEL_NAME' ya existe, se reutiliza."
else
  cloudflared tunnel create "$TUNNEL_NAME"
fi
TUNNEL_ID="$(cloudflared tunnel list --output json \
  | python3 -c "import sys,json; print(next(t['id'] for t in json.load(sys.stdin) if t['name']=='$TUNNEL_NAME'))")"
echo ">> Tunnel ID: $TUNNEL_ID"

# 4. Copiar credenciales y config
mkdir -p "$CONF_DIR"
cp "$HOME/.cloudflared/${TUNNEL_ID}.json" "$CONF_DIR/"
chmod 600 "$CONF_DIR/${TUNNEL_ID}.json"
sed "s/__TUNNEL_ID__/${TUNNEL_ID}/g" "$SCRIPT_DIR/config.yml" > "$CONF_DIR/config.yml"

cloudflared tunnel --config "$CONF_DIR/config.yml" ingress validate

# 5. Crear registros DNS (CNAME -> <id>.cfargotunnel.com)
for h in "${HOSTNAMES[@]}"; do
  echo ">> DNS: $h"
  cloudflared tunnel route dns --overwrite-dns "$TUNNEL_NAME" "$h"
done

# 6. Instalar como servicio systemd
if ! systemctl list-unit-files | grep -q '^cloudflared.service'; then
  cloudflared --config "$CONF_DIR/config.yml" service install
fi
systemctl enable --now cloudflared
systemctl restart cloudflared
sleep 3
systemctl --no-pager status cloudflared | head -n 15

echo
echo "Listo. Prueba: curl -I https://cms.${DOMAIN}"
