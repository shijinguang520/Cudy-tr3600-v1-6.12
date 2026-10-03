#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update Feeds)
#
# Copyright (c) 2019-2024 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

# =========================================================
# 修改默认 IP 地址（可选）
# =========================================================

# 将默认 IP 从 192.168.1.1 改为 192.168.6.1
sed -i 's/192.168.1.1/192.168.6.1/g' package/base-files/files/bin/config_generate

# =========================================================
# 修改默认主机名（可选）
# =========================================================

# sed -i 's/OpenWrt/Cudy-TR3600/g' package/base-files/files/bin/config_generate

# =========================================================
# 修改默认时区（可选）
# =========================================================

# 设置默认LuCI主题为argon
sed -i 's/luci.main.theme=bootstrap/luci.main.theme=argon/' package/base-files/files/etc/config/luci
# 备份兼容写法，防止上面没匹配到
echo "uci set luci.main.theme='argon'" >> package/base-files/files/etc/uci-defaults/99-default-theme
echo "uci commit luci" >> package/base-files/files/etc/uci-defaults/99-default-theme
#

# =========================================================
# Cudy TR3600 v1 —— 风扇 PWM 修复（设备树补丁）
# 追加段：2026-10 添加
#
# 问题：上游 DTS 把风扇 PWM 配到了错误的通道和引脚
#   - pwms   = <&pwm 1 ...>     错(通道1)       应为 <&pwm 0 ...>  通道0
#   - groups = "pwm1_0"         错(pin7/JTAG)   应为 "pwm0"       pin13/PWM0
#   后果：PWM 信号从不驱动风扇引脚 → 风扇只要通电就满速、管理页调速无效
# =========================================================

DTS="target/linux/mediatek/dts/mt7987b-cudy-tr3600-v1.dts"

echo "===== TR3600 fan fix ====="

if [ ! -f "$DTS" ]; then
    echo "!! 找不到 $DTS，跳过风扇修复"
else
    cp -f "$DTS" "${DTS}.orig-fanfix"

    # 1) PWM 通道 1 -> 0
    sed -i 's|pwms = <&pwm 1 50000 0>;|pwms = <\&pwm 0 50000 0>;|' "$DTS"

    # 2) 风扇档位（0 / 25% / 50% / 75% / 100%），仅在缺失时插入
    if ! grep -q 'cooling-levels' "$DTS"; then
        sed -i 's|^\(\s*\)pwms = <&pwm 0 50000 0>;|\1cooling-levels = <0 64 128 192 255>;\n\1pwms = <\&pwm 0 50000 0>;|' "$DTS"
    fi

    # 3) 引脚复用：pwm1_0 (pin7) -> pwm0 (pin13)
    sed -i 's|groups = "pwm1_0";|groups = "pwm0";|' "$DTS"
    sed -i 's|pwm1_pins: pwm1-pins|pwm0_pins: pwm0-pins|' "$DTS"
    sed -i 's|pinctrl-0 = <&pwm1_pins>;|pinctrl-0 = <\&pwm0_pins>;|' "$DTS"

    # 4) 校验
    echo "--- 修复结果 ---"
    grep -nE 'pwms = <&pwm|cooling-levels|groups = "pwm|pinctrl-0 = <&pwm' "$DTS"

    FAIL=0
    grep -q 'pwms = <&pwm 0 50000 0>;' "$DTS" || { echo "!! 失败: PWM 通道未改为 0"; FAIL=1; }
    grep -q 'groups = "pwm0";'          "$DTS" || { echo "!! 失败: 引脚组未改为 pwm0"; FAIL=1; }
    grep -q 'pinctrl-0 = <&pwm0_pins>;' "$DTS" || { echo "!! 失败: pinctrl 未改为 pwm0_pins"; FAIL=1; }

    if [ "$FAIL" = "0" ]; then
        echo "===== fan fix OK ====="
    else
        echo "===== fan fix FAILED（DTS 结构可能不同，请检查上面的 grep 输出）====="
    fi
fi
