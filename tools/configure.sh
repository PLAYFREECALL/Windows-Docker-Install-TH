#!/usr/bin/env bash
# configure.sh — สร้างไฟล์ windows.yml แบบถาม-ตอบ
# ใช้: ./tools/configure.sh [--defaults] [--output ไฟล์]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="$ROOT_DIR/windows.yml"
USE_DEFAULTS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --defaults) USE_DEFAULTS=1 ;;
    --output|-o) OUTPUT="$2"; shift ;;
    -h|--help) echo "ใช้: $0 [--defaults] [--output ไฟล์]"; exit 0 ;;
    *) echo "ไม่รู้จักตัวเลือก: $1" >&2; exit 1 ;;
  esac
  shift
done

# ค่าเริ่มต้นเหมือน windows.yml ต้นฉบับ
VERSION="10l"; USERNAME="User"; PASSWORD=""
RAM_SIZE="4G"; CPU_CORES="2"; DISK_SIZE="20G"; DISK2_SIZE="2G"

warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

ask() { # ask <ตัวแปร> <ข้อความ> <regex>
  local var="$1" prompt="$2" re="$3" cur ans
  cur="${!var}"
  while true; do
    read -r -p "$prompt [$cur]: " ans
    ans="${ans:-$cur}"
    if [[ -z "$re" || "$ans" =~ $re ]]; then printf -v "$var" '%s' "$ans"; return; fi
    warn "รูปแบบไม่ถูกต้อง ลองใหม่อีกครั้ง"
  done
}

choose_version() {
  echo "เลือกเวอร์ชัน Windows:"
  echo "  1) 11   — Windows 11 Pro"
  echo "  2) 11l  — Windows 11 LTSC"
  echo "  3) 10   — Windows 10 Pro"
  echo "  4) 10l  — Windows 10 LTSC (แนะนำ ประหยัดทรัพยากร)"
  echo "  5) 7u   — Windows 7 Ultimate"
  echo "  6) ใส่ลิงก์ไฟล์ ISO เอง (เช่น Tiny10)"
  local c
  read -r -p "หมายเลข [4]: " c
  case "${c:-4}" in
    1) VERSION="11" ;; 2) VERSION="11l" ;; 3) VERSION="10" ;; 4) VERSION="10l" ;; 5) VERSION="7u" ;;
    6) read -r -p "ลิงก์ ISO (https://...): " VERSION
       [[ "$VERSION" =~ ^https?:// ]] || { warn "ลิงก์ไม่ถูกต้อง ใช้ค่า 10l แทน"; VERSION="10l"; } ;;
    *) warn "ตัวเลือกไม่ถูกต้อง ใช้ค่า 10l"; VERSION="10l" ;;
  esac
}

check_resources() {
  local ram_gb free_gb
  ram_gb="$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)"
  free_gb="$(df -BG --output=avail "$ROOT_DIR" 2>/dev/null | tail -n1 | tr -dc '0-9')"
  if (( ram_gb > 0 && ${RAM_SIZE%G} >= ram_gb )); then
    warn "RAM ที่ตั้ง (${RAM_SIZE}) มากกว่าหรือเท่ากับ RAM เครื่อง (${ram_gb}G) — อาจทำให้ระบบค้าง"
  fi
  if (( CPU_CORES > $(nproc) )); then
    warn "CPU ที่ตั้ง (${CPU_CORES}) มากกว่าจำนวนคอร์เครื่อง ($(nproc))"
  fi
  if [[ -n "$free_gb" ]] && (( ${DISK_SIZE%G} + 3 > free_gb )); then
    warn "พื้นที่ว่าง (${free_gb}G) อาจไม่พอสำหรับดิสก์ ${DISK_SIZE} + สำรอง 3G"
  fi
}

if (( ! USE_DEFAULTS )); then
  echo "=== ตั้งค่า Windows ผ่าน Docker ==="
  choose_version
  ask USERNAME   "ชื่อผู้ใช้"                 '^[A-Za-z0-9_.-]+$'
  read -r -s -p "รหัสผ่าน (เว้นว่างได้): " PASSWORD; echo
  ask RAM_SIZE   "RAM (เช่น 4G)"             '^[0-9]+G$'
  ask CPU_CORES  "จำนวน CPU core"            '^[1-9][0-9]*$'
  ask DISK_SIZE  "ขนาดดิสก์หลัก (เช่น 20G)"   '^[0-9]+G$'
  ask DISK2_SIZE "ขนาดดิสก์เสริม (เช่น 2G)"   '^[0-9]+G$'
  check_resources
fi

if [[ -f "$OUTPUT" ]]; then
  cp "$OUTPUT" "$OUTPUT.bak"
  echo "สำรองไฟล์เดิมไว้ที่ $OUTPUT.bak"
fi

yq() { local s="${1//\\/\\\\}"; printf '"%s"' "${s//\"/\\\"}"; } # ใส่เครื่องหมายคำพูดแบบ YAML

{
cat <<EOF
volumes:
  windows_main_data:
  windows_extra_data:

services:
  windows:
    image: dockurr/windows
    container_name: windows
    environment:
      VERSION: $(yq "$VERSION")
      USERNAME: $(yq "$USERNAME")
EOF
[[ -n "$PASSWORD" ]] && echo "      PASSWORD: $(yq "$PASSWORD")"
cat <<EOF
      RAM_SIZE: $(yq "$RAM_SIZE")
      CPU_CORES: $(yq "$CPU_CORES")
      DISK_SIZE: $(yq "$DISK_SIZE")
      DISK2_SIZE: $(yq "$DISK2_SIZE")
    devices:
      - /dev/kvm
      - /dev/net/tun
    cap_add:
      - NET_ADMIN
    ports:
      - "8006:8006"
      - "3389:3389/tcp"
      - "3389:3389/udp"
    volumes:
      - windows_main_data:/data
      - windows_extra_data:/extra
    stop_grace_period: 2m
EOF
} > "$OUTPUT"

echo "บันทึกการตั้งค่าที่ $OUTPUT แล้ว — เริ่มใช้งานด้วย './win.sh start'"
echo "หมายเหตุ: การเปลี่ยนเวอร์ชันมีผลเฉพาะการติดตั้งครั้งแรก (ต้อง './win.sh reset' ถ้าจะลงใหม่)"
