#!/bin/bash

# ---------------------------------------------------------
# 双重保险：终结 OpenClash 带来的 Rust 漫长编译噩梦
# ---------------------------------------------------------
echo ">>> 开始执行双重拦截：关闭 Ruby YJIT，跳过 rust/host 编译..."

# ==========================================
# 方案 A：先从顶层配置文件强制取消 YJIT 编译
# ==========================================
# 遍历当前目录下的系统 .config 以及你仓库里的自定义 config (如 mt7986.config)
for conf in .config *.config; do
    if [ -f "$conf" ]; then
        # 1. 剔除可能存在的开启选项 (防冲突)
        sed -i '/CONFIG_RUBY_ENABLE_YJIT/d' "$conf"
        # 2. 强行追加关闭指令 (最高优先级)
        echo "# CONFIG_RUBY_ENABLE_YJIT is not set" >> "$conf"
        echo "✅ 方案 A 成功：已在 $conf 中强制声明关闭 RUBY_ENABLE_YJIT"
    fi
done

# ==========================================
# 方案 B：修改底层 Makefile，物理斩断依赖引擎
# ==========================================
RUBY_MK=$(find feeds -name "Makefile" -path "*/lang/ruby/Makefile" 2>/dev/null | head -n 1)

if [ -f "$RUBY_MK" ]; then
    echo ">>> 正在魔改 Ruby Makefile，执行物理级依赖阉割..."
    
    # 1. 防弹级正则破坏：在 config RUBY_ENABLE_YJIT 和 help 之间，将 default y 强制改为 default n
    sed -i '/config RUBY_ENABLE_YJIT/,/help/{s/default y.*/default n/g}' "$RUBY_MK"
    
    # 2. 釜底抽薪：精准删掉引发 Rust 编译的宿主机依赖关键词
    # sed -i 's/RUBY_ENABLE_YJIT:rust\/host//g' "$RUBY_MK"
    
    echo "✅ 方案 B 成功：Ruby 对 Rust 的依赖链已被彻底斩断！"
else
    echo "⚠️ 警告: 未找到 Ruby 的 Makefile，可能路径有变，方案 B 跳过。"
fi

echo "🎉 双重拦截部署完毕！"


# =========================================================
# Cudy TR3600 v1 风扇修复（2026-10 追加）
# =========================================================
# 问题 1 —— 设备树把风扇 PWM 配到了错误的通道和引脚：
#     pwms   = <&pwm 1 50000 0>;   错(通道1)      应为 <&pwm 0 ...>  通道0
#     groups = "pwm1_0";           错(pin7/JTAG)  应为 "pwm0"        pin13/PWM0
#   后果：PWM 信号从不驱动风扇引脚 → 风扇只要通电就满速、调速完全无效
#
# 问题 2 —— luci-app-tr3600-fan 打包后脚本没有执行位（0644）：
#   导致 LuCI 页面报“未检测到 PWM 风扇冷却设备”，守护进程也起不来
# =========================================================

echo "===== TR3600 fan fix ====="

# ---------- 1) 设备树修复 ----------
DTS=$(find target/linux/mediatek/dts -name 'mt7987b-cudy-tr3600*.dts' 2>/dev/null | head -n 1)
[ -z "$DTS" ] && DTS=$(find target/linux -name '*cudy-tr3600*.dts' 2>/dev/null | head -n 1)

if [ -z "$DTS" ] || [ ! -f "$DTS" ]; then
    echo "!! 未找到 TR3600 设备树文件，设备树修复跳过"
else
    echo "DTS: $DTS"
    cp -f "$DTS" "${DTS}.orig-fanfix"

    # PWM 通道 1 -> 0
    sed -i 's|pwms = <&pwm 1 50000 0>;|pwms = <\&pwm 0 50000 0>;|' "$DTS"
    # 引脚复用 pwm1_0(pin7) -> pwm0(pin13)
    sed -i 's|groups = "pwm1_0";|groups = "pwm0";|' "$DTS"
    sed -i 's|pwm1_pins: pwm1-pins|pwm0_pins: pwm0-pins|' "$DTS"
    sed -i 's|pinctrl-0 = <&pwm1_pins>;|pinctrl-0 = <\&pwm0_pins>;|' "$DTS"
    # 风扇档位（0 / 25% / 50% / 75% / 100%），缺失才插入
    if ! grep -q 'cooling-levels' "$DTS"; then
        sed -i 's|^\(\s*\)pwms = <&pwm 0 50000 0>;|\1cooling-levels = <0 64 128 192 255>;\n\1pwms = <\&pwm 0 50000 0>;|' "$DTS"
    fi

    echo "--- 修复后 fan/pwm 相关行 ---"
    grep -nE 'pwms = <&pwm|cooling-levels|groups = "pwm|pinctrl-0 = <&pwm' "$DTS"

    DF=0
    grep -q 'pwms = <&pwm 0 50000 0>;' "$DTS" || { echo "!! FAIL: PWM 通道未改成 0"; DF=1; }
    grep -q 'groups = "pwm0";'          "$DTS" || { echo "!! FAIL: 引脚组未改成 pwm0"; DF=1; }
    grep -q 'pinctrl-0 = <&pwm0_pins>;' "$DTS" || { echo "!! FAIL: pinctrl 未改成 pwm0_pins"; DF=1; }
    if [ "$DF" = "0" ]; then echo "===== DTS fix OK ====="; else echo "===== DTS fix FAILED ====="; fi
fi

# ---------- 2) 风扇 App 脚本执行权限修复 ----------
FANAPP="package/custom/luci-app-tr3600-fan"
if [ -d "$FANAPP" ]; then
    chmod 755 "$FANAPP/root/usr/sbin/tr3600-fan"            2>/dev/null
    chmod 755 "$FANAPP/root/etc/init.d/tr3600-fan"          2>/dev/null
    chmod 755 "$FANAPP/root/etc/uci-defaults/99-tr3600-fan" 2>/dev/null
    echo "--- 风扇脚本权限 ---"
    ls -l "$FANAPP/root/usr/sbin/tr3600-fan" "$FANAPP/root/etc/init.d/tr3600-fan" 2>/dev/null
    echo "===== perm fix done ====="
else
    echo "!! 未找到 $FANAPP，权限修复跳过（检查 diy-part1 里的克隆路径）"
fi
