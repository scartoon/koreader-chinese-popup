#!/bin/sh
# Check, push the plugin to a USB-connected Android device and restart KOReader.
#     tools/deploy.sh [path/to/book.epub on the device]
# Set PINYIN_PLUGIN=/path/to/interlinearpinyin.koplugin to push that plugin too.
set -e
cd "$(dirname "$0")/.."
tools/check.sh
DEST=/sdcard/koreader/plugins
adb shell rm -rf "$DEST/chinesepopup.koplugin"
adb push chinesepopup.koplugin "$DEST/" >/dev/null
if [ -n "$PINYIN_PLUGIN" ]; then
    adb shell rm -rf "$DEST/interlinearpinyin.koplugin"
    adb push "$PINYIN_PLUGIN" "$DEST/" >/dev/null
fi
adb shell am force-stop org.koreader.launcher
if [ -n "$1" ]; then
    adb shell am start -n org.koreader.launcher/.MainActivity -a android.intent.action.VIEW \
        -d "file://$1" -t application/epub+zip >/dev/null
else
    adb shell monkey -p org.koreader.launcher -c android.intent.category.LAUNCHER 1 >/dev/null
fi
echo "pushed and restarted"
