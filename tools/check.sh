#!/usr/bin/env bash
# check.sh — ตรวจสุขภาพระบบก่อน/ระหว่างใช้งาน Windows ผ่าน Docker
# exit code: 0 = ผ่าน (อาจมีคำเตือน), 1 = มีปัญหาที่ต้องแก้ (❌)
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/windows.yml}"
MIN_FREE_GB=3
FAIL=0

pass() { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }
fail() { echo "❌ $*"; FAIL=1; }

cfg() { # อ่านค่าจาก windows.yml
  [[ -f "$COMPOSE_FILE" ]] || return 0
  sed -n "s/^[[:space:]]*$1:[[:space:]]*\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*$/\1/p" "$COMPOSE_FILE" | head -n1
}

echo "=== ตรวจสุขภาพระบบ ==="

# 1) KVM
if [[ -e /dev/kvm ]]; then
  if [[ -r /dev/kvm && -w /dev/kvm ]] || [[ $EUID -eq 0 ]]; then
    pass "พบ /dev/kvm (รองรับ virtualization)"
  else
    warn "พบ /dev/kvm แต่ผู้ใช้ปัจจุบันไม่มีสิทธิ์ (Docker มักจะใช้ได้ผ่าน root)"
  fi
else
  fail "ไม่พบ /dev/kvm — เครื่องนี้ไม่รองรับ KVM (Codespaces ควรเลือก 4 core ขึ้นไป)"
fi

# 2) Docker
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1 || sudo -n docker info >/dev/null 2>&1; then
    pass "Docker ทำงานอยู่"
  else
    fail "ติดตั้ง Docker แล้วแต่ daemon ไม่ทำงาน (ลอง 'sudo service docker start')"
  fi
else
  fail "ยังไม่ได้ติดตั้ง Docker (รัน './win.sh install')"
fi

# 3) พื้นที่ดิสก์
DISK_SIZE="$(cfg DISK_SIZE)"; DISK_SIZE="${DISK_SIZE%G}"
check_disk() {
  local path="$1" label="$2" free
  [[ -d "$path" ]] || return 0
  free="$(df -BG --output=avail "$path" 2>/dev/null | tail -n1 | tr -dc '0-9')"
  [[ -n "$free" ]] || return 0
  if (( free < MIN_FREE_GB )); then
    fail "$label เหลือพื้นที่ ${free}G (ต้องมีอย่างน้อย ${MIN_FREE_GB}G มิฉะนั้นข้อมูล Windows อาจเสียหาย)"
  elif [[ -n "$DISK_SIZE" && "$DISK_SIZE" =~ ^[0-9]+$ ]] && (( free < DISK_SIZE + MIN_FREE_GB )); then
    warn "$label เหลือ ${free}G — น้อยกว่าขนาดดิสก์ Windows (${DISK_SIZE}G) + ${MIN_FREE_GB}G"
  else
    pass "$label เหลือพื้นที่ ${free}G"
  fi
}
check_disk / "ดิสก์ระบบ (/)"
check_disk /var/lib/docker "ดิสก์ Docker (/var/lib/docker)"

# 4) RAM / CPU เทียบกับการตั้งค่า
RAM_CFG="$(cfg RAM_SIZE)"; CPU_CFG="$(cfg CPU_CORES)"
RAM_HOST="$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)"
CPU_HOST="$(nproc 2>/dev/null || echo 0)"
if [[ "${RAM_CFG%G}" =~ ^[0-9]+$ ]] && (( RAM_HOST > 0 )); then
  if (( ${RAM_CFG%G} >= RAM_HOST )); then
    warn "ตั้ง RAM ${RAM_CFG} แต่เครื่องมี ${RAM_HOST}G — ควรลดลง"
  else
    pass "RAM: ตั้ง ${RAM_CFG} / เครื่องมี ${RAM_HOST}G"
  fi
fi
if [[ "$CPU_CFG" =~ ^[0-9]+$ ]] && (( CPU_HOST > 0 )); then
  if (( CPU_CFG > CPU_HOST )); then
    warn "ตั้ง CPU ${CPU_CFG} core แต่เครื่องมี ${CPU_HOST} core"
  else
    pass "CPU: ตั้ง ${CPU_CFG} core / เครื่องมี ${CPU_HOST} core"
  fi
fi
[[ -f "$COMPOSE_FILE" ]] || warn "ไม่พบ $COMPOSE_FILE (สร้างด้วย './win.sh config')"

# 5) สถานะคอนเทนเนอร์
if command -v docker >/dev/null 2>&1; then
  D="docker"; docker info >/dev/null 2>&1 || D="sudo -n docker"
  state="$($D inspect -f '{{.State.Status}}|{{.State.StartedAt}}' windows 2>/dev/null || true)"
  if [[ -n "$state" ]]; then
    status="${state%%|*}"; started="${state#*|}"
    if [[ "$status" == "running" ]]; then
      secs=$(( $(date +%s) - $(date -d "$started" +%s 2>/dev/null || date +%s) ))
      pass "คอนเทนเนอร์ windows กำลังทำงาน ($((secs/3600)) ชม. $((secs%3600/60)) นาที)"
    else
      echo "ℹ️  คอนเทนเนอร์ windows สถานะ: $status"
    fi
  else
    echo "ℹ️  ยังไม่มีคอนเทนเนอร์ windows"
  fi
fi

# 6) โควต้า Codespaces
if [[ "${CODESPACES:-}" == "true" ]]; then
  up="$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo 0)"
  echo "ℹ️  Codespace นี้เปิดมาแล้ว $((up/3600)) ชม. $((up%3600/60)) นาที (ใช้ ${CPU_HOST} core = $((CPU_HOST*up/3600)) core-hour)"
  warn "อย่าลืมหยุด Codespace เมื่อเลิกใช้ เพื่อประหยัดโควต้า (ตรวจได้ที่ https://github.com/settings/billing/summary)"
fi

echo
if (( FAIL )); then echo "ผลตรวจ: มีปัญหาที่ต้องแก้ไข"; else echo "ผลตรวจ: พร้อมใช้งาน"; fi
exit "$FAIL"
