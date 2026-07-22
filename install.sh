#!/usr/bin/env bash
# vps-auto 首次安装：将 vps_auto_work_cc.sh 安装到 /root/.1/
set -euo pipefail

INSTALL_DIR="/root/.1"
INSTALL_PATH="${INSTALL_DIR}/vps_auto_work_cc.sh"
MANIFEST_URL="${MANIFEST_URL:-https://raw.githubusercontent.com/alpha302/vps-auto/main/version.json}"
BASE_RAW="${BASE_RAW:-https://raw.githubusercontent.com/alpha302/vps-auto/main}"

if [ "$(id -u)" -ne 0 ]; then
  echo "[ERROR] 请使用 root 或 sudo 运行" >&2
  exit 1
fi

tmpdir=$(mktemp -d /tmp/vps_auto_install.XXXXXX)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

manifest="${tmpdir}/version.json"
curl -fsSL --max-time 30 "$MANIFEST_URL" -o "$manifest"

version=$(grep -oP '"version"\s*:\s*"\K[^"]+' "$manifest" | head -1)
sha256=$(grep -oP '"sha256"\s*:\s*"\K[^"]+' "$manifest" | head -1)
script_url=$(grep -oP '"script_url"\s*:\s*"\K[^"]+' "$manifest" | head -1)
[ -n "$script_url" ] || script_url="${BASE_RAW}/vps_auto_work_cc.sh"

echo "[INFO] 安装 vps_auto_work_cc.sh v${version:-未知} ..."

new_script="${tmpdir}/vps_auto_work_cc.sh"
curl -fsSL --max-time 120 "$script_url" -o "$new_script"
bash -n "$new_script"

if [ -n "$sha256" ]; then
  echo "${sha256}  ${new_script}" > "${tmpdir}/sha256sum.txt"
  sha256sum -c "${tmpdir}/sha256sum.txt"
fi

mkdir -p "$INSTALL_DIR"
if [ -f "$INSTALL_PATH" ]; then
  cp -a "$INSTALL_PATH" "${INSTALL_PATH}.bak.$(date +%Y%m%d%H%M%S)"
fi
install -m 755 "$new_script" "$INSTALL_PATH"

echo "[OK] 已安装: ${INSTALL_PATH}"
echo "[OK] 查看帮助: sudo bash ${INSTALL_PATH} -h"
echo "[OK] 检查更新: sudo bash ${INSTALL_PATH} -update-check"
