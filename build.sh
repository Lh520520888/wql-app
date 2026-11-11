#!/bin/bash
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"

echo "==> 环境检查"
uname -s | grep -q Darwin || { echo "必须在 macOS 上构建"; exit 1; }

if [ -z "$THEOS" ]; then
    for p in "$HOME/theos" "/opt/theos" "/usr/local/theos"; do
        [ -d "$p" ] && export THEOS="$p" && break
    done
fi
[ -z "$THEOS" ] && { echo "请先安装 theos: https://theos.dev/docs/installation-macos"; exit 1; }
echo "    THEOS=$THEOS"

echo "==> 编译"
cd "$HERE"
rm -rf .theos .ipa WQLApp.ipa
make clean 2>/dev/null || true
make -j"$(sysctl -n hw.ncpu)" package
make ipa

echo "==> 完成: $HERE/WQLApp.ipa"
echo
echo "签名前三件事，缺一不可："
echo "  1. entitlements.plist 里的 application-identifier 要补成 <TeamID>.com.wql.app"
echo "  2. com.apple.developer.team-identifier 换成真实 TeamID"
echo "  3. 描述文件（mobileprovision）里必须带 App Group capability，值 = group.com.rails.mobilePlatform"
echo "     —— 这步做不到，containerURLForSecurityApplicationGroupIdentifier 会返回 nil，通道直接断在第一步"
echo
echo "签名示例："
echo "  codesign -f -s \"iPhone Distribution: xxx\" --entitlements entitlements.plist Payload/WQLApp.app"
echo "  或 ldid -Sentitlements.plist Payload/WQLApp.app/WQLApp"