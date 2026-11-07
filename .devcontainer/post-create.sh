#!/usr/bin/env bash
# รันอัตโนมัติหลังสร้าง Codespace
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
chmod +x win.sh tools/*.sh
./tools/check.sh || true
echo
echo "พร้อมแล้ว! เริ่ม Windows ด้วยคำสั่ง:  ./win.sh start"
echo "ปรับการตั้งค่า (เวอร์ชัน/RAM/ดิสก์):  ./win.sh config"
