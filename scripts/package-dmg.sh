#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ARCH="${1:-$(uname -m)}"
case "$ARCH" in arm64) PLATFORM="Apple Silicon（苹果芯片）";; x86_64) PLATFORM="Intel（英特尔芯片）";; *) echo "Unsupported architecture: $ARCH" >&2; exit 2;; esac
./scripts/build.sh "$ARCH"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/kma-flash-dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
ditto "build/$ARCH/同页.app" "$STAGING/同页.app"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/安装说明.txt" <<TEXT
同页

将「同页.app」拖到 Applications（应用程序）后打开。
首次启动书房为空，请导入自己的 PDF、TXT、Markdown、代码 ZIP，或粘贴正文与公开网页链接。

应用不附带任何内置阅读资料。升级会保留已有资料、笔记和阅读进度。
模型列表仅含无 API Key 的 Demo 示例；请在模型设置复制为自定义模型并填写自己的连接信息。
系统要求：$PLATFORM Mac，macOS 14 或更新版本。
TEXT
DMG="$PWD/build/同页-$VERSION-$ARCH.dmg"
hdiutil create -volname "同页 $VERSION $ARCH" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
hdiutil verify "$DMG"
codesign --verify --deep --strict "build/$ARCH/同页.app"
LC_ALL=C shasum -a 256 "$DMG" > "$DMG.sha256"
printf 'DMG: %s\n' "$DMG"
