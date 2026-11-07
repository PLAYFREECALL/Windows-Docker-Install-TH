#!/usr/bin/env bash
# win.sh — เครื่องมือช่วยจัดการ Windows ผ่าน Docker
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/windows.yml}"
CONTAINER="windows"
VOLUME_SUFFIX="windows_main_data"

info() { printf '\033[1;34m[ℹ]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[✓]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[✗]\033[0m %s\n' "$*" >&2; exit 1; }

# ใช้ sudo เฉพาะเมื่อไม่ใช่ root และเข้าถึง docker ไม่ได้
SUDO=""
need_sudo() {
  if [[ $EUID -ne 0 ]] && ! docker info >/dev/null 2>&1; then
    command -v sudo >/dev/null 2>&1 && SUDO="sudo"
  fi
}

compose() {
  need_sudo
  if docker compose version >/dev/null 2>&1 || $SUDO docker compose version >/dev/null 2>&1; then
    $SUDO docker compose -f "$COMPOSE_FILE" "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    $SUDO docker-compose -f "$COMPOSE_FILE" "$@"
  else
    die "ไม่พบ docker compose — รัน './win.sh install' ก่อน"
  fi
}

require_compose_file() {
  [[ -f "$COMPOSE_FILE" ]] || die "ไม่พบไฟล์ $COMPOSE_FILE — รัน './win.sh config' เพื่อสร้าง"
}

cmd_help() {
  cat <<'EOF'
วิธีใช้: ./win.sh <คำสั่ง>

  install        ติดตั้ง Docker (ถ้ายังไม่มี) ตรวจระบบ แล้วเริ่ม Windows
  start          เริ่ม / สร้างคอนเทนเนอร์ Windows (ทำงานเบื้องหลัง)
  stop           หยุด Windows (ข้อมูลไม่หาย)
  restart        รีสตาร์ท Windows
  status         ดูสถานะคอนเทนเนอร์
  logs [-f]      ดู log (ใส่ -f เพื่อติดตามต่อเนื่อง)
  url            แสดงลิงก์เข้าใช้งาน (พอร์ต 8006 / 3389)
  config         สร้างไฟล์ windows.yml แบบถาม-ตอบ
  check          ตรวจสุขภาพระบบ (KVM, Docker, พื้นที่ดิสก์, โควต้า)
  backup [dir]   สำรองข้อมูลดิสก์ Windows เป็น .tar.gz (ค่าเริ่มต้น ./backup)
  reset          ลบคอนเทนเนอร์และข้อมูล Windows ทั้งหมด (ย้อนกลับไม่ได้!)
  help           แสดงข้อความนี้
EOF
}

cmd_install() {
  if ! command -v docker >/dev/null 2>&1; then
    info "กำลังติดตั้ง Docker..."
    local s=""; [[ $EUID -ne 0 ]] && s="sudo"
    $s apt-get update
    $s apt-get install -y docker.io docker-compose
    ok "ติดตั้ง Docker เรียบร้อย"
  else
    ok "มี Docker อยู่แล้ว"
  fi
  "$ROOT_DIR/tools/check.sh" || die "การตรวจระบบไม่ผ่าน กรุณาแก้ไขตามรายการ ❌ ด้านบนก่อน"
  [[ -f "$COMPOSE_FILE" ]] || "$ROOT_DIR/tools/configure.sh" --defaults
  cmd_start
}

cmd_start() {
  require_compose_file
  info "กำลังเริ่ม Windows... (ครั้งแรกจะดาวน์โหลดและติดตั้ง ใช้เวลาสักพัก)"
  compose up -d
  ok "เริ่มทำงานแล้ว"
  cmd_url
}

cmd_url() {
  if [[ "${CODESPACES:-}" == "true" && -n "${CODESPACE_NAME:-}" ]]; then
    local domain="${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-app.github.dev}"
    info "ดูหน้าจอ Windows ผ่านเว็บ: https://${CODESPACE_NAME}-8006.${domain}"
  else
    info "ดูหน้าจอ Windows ผ่านเว็บ: http://localhost:8006"
  fi
  info "Remote Desktop (RDP): พอร์ต 3389 (ใช้ได้หลังติดตั้ง Windows เสร็จ)"
}

cmd_backup() {
  require_compose_file
  local dir="${1:-$ROOT_DIR/backup}"
  mkdir -p "$dir"
  dir="$(cd "$dir" && pwd)"
  need_sudo
  local vol
  vol="$($SUDO docker volume ls -q | grep -E "(^|_)${VOLUME_SUFFIX}\$" | head -n1 || true)"
  [[ -n "$vol" ]] || die "ไม่พบ volume ข้อมูล Windows (${VOLUME_SUFFIX})"
  local out="windows-$(date +%Y%m%d-%H%M%S).tar.gz"
  warn "ต้องหยุด Windows ระหว่างสำรองข้อมูล และไฟล์อาจใหญ่หลาย GB — ตรวจพื้นที่ดิสก์ให้พอ"
  compose stop
  info "กำลังสำรอง volume '$vol' ไปที่ $dir/$out ..."
  $SUDO docker run --rm -v "$vol":/data:ro -v "$dir":/backup alpine \
    tar czf "/backup/$out" -C /data .
  ok "สำรองข้อมูลเสร็จ: $dir/$out ($(du -h "$dir/$out" | cut -f1))"
  info "เริ่ม Windows อีกครั้งด้วย './win.sh start'"
}

cmd_reset() {
  require_compose_file
  warn "คำสั่งนี้จะลบ Windows และข้อมูลทั้งหมดในคอนเทนเนอร์ ไม่สามารถกู้คืนได้!"
  read -r -p "พิมพ์ YES เพื่อยืนยัน: " ans
  [[ "$ans" == "YES" ]] || { info "ยกเลิกแล้ว"; return 0; }
  compose down -v
  ok "ลบเรียบร้อย"
}

main() {
  local cmd="${1:-help}"; shift || true
  case "$cmd" in
    install) cmd_install ;;
    start)   cmd_start ;;
    stop)    require_compose_file; compose stop; ok "หยุด Windows แล้ว" ;;
    restart) require_compose_file; compose restart; ok "รีสตาร์ทแล้ว" ;;
    status)  require_compose_file; compose ps ;;
    logs)    require_compose_file; compose logs --tail=100 "$@" ;;
    url)     cmd_url ;;
    config)  "$ROOT_DIR/tools/configure.sh" "$@" ;;
    check)   "$ROOT_DIR/tools/check.sh" ;;
    backup)  cmd_backup "$@" ;;
    reset)   cmd_reset ;;
    help|-h|--help) cmd_help ;;
    *) cmd_help; die "ไม่รู้จักคำสั่ง: $cmd" ;;
  esac
}

main "$@"
