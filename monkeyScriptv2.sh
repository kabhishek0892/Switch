#!/bin/bash
LOCATION=$(dirname "$0")
source "$LOCATION"/common_tools.sh
trap 'ctrlc' 1 2 3 6 15

ctrlc(){
  if $RUNNING_TESTS; then
    MONKEY_TASK_ID=$(adb -s "$SELECTED_DEVICE" shell pidof "com.android.commands.monkey")
    adb -s "$SELECTED_DEVICE" shell kill "$MONKEY_TASK_ID" >/dev/null 2>&1
    echo "🔪 Test monkey terminated, the device is safe to use now!"
  fi

  unlock_app_fullscreen "$SELECTED_DEVICE"
  exit 2
}

unlock_app_fullscreen(){
  adb -s "$1" shell am task lock stop >/dev/null 2>&1
  echo "🔓 App fullscreen pinning disabled"
}

update_package_name(){
  APP_PACKAGE_NAME="$(android_get_foreground_package "$1")"
}

check_screen_pinning(){
  PINNING_ENABLED=$(adb -s "$1" shell settings get system lock_to_app_enabled)
  PINNING_ENABLED=${PINNING_ENABLED%$'\r'} # remove trailing carriage return
  if [ "$PINNING_ENABLED" != "1" ]; then
    adb -s "$1" shell am start -a android.settings.SECURITY_SETTINGS >/dev/null 2>&1
    read -r -p "🔑 Enable \"Screen pinning\" option in security settings, then press enter..."
  fi
}

lock_task_fullscreen(){
  check_screen_pinning "$1"
  adb -s "$1" shell monkey -p "$APP_PACKAGE_NAME" -c android.intent.category.LAUNCHER 1 &> /dev/null
  adb -s "$1" shell input keyevent "KEYCODE_APP_SWITCH"
  read -r -p "📌 Press the \"Pin\" button in \"$APP_PACKAGE_NAME\" window, then press enter... " #TODO add check if already on
}

run_test(){
  SEED="$2"
  EVENT_COUNT="$3"
  tput setaf 3 && should_proceed "🔥 DANGER ZONE ⊗ Send $EVENT_COUNT monkey test events to \"$APP_PACKAGE_NAME\"? (may take a while)" && tput sgr0 #set red and white text color
  echo "🐒 Running monkey stress test... (press ctrl^c to end now)"
  RUNNING_TESTS=true
  LOG_FILE=~/Desktop/"monkey-test-log-$SEED-$APP_PACKAGE_NAME-$MANUFACTURER-$MODEL-API$SDK-$(date +%Y-%m-%d-%H-%M-%S).txt"
  adb -s "$1" shell monkey -p "$APP_PACKAGE_NAME" -s "$SEED" --pct-appswitch 0 --pct-syskeys 0 --pct-anyevent 0 "$EVENT_COUNT" &> "$LOG_FILE"
  unlock_app_fullscreen "$@"
  grep -q "CRASH" "$LOG_FILE" && tput setaf 1 && echo "❌ Test failed, see crash log for details, seed: $SEED" && tput sgr0 && open "$LOG_FILE" && exit 1
  tput setaf 2 && echo "✅ Test passed, successfully executed $EVENT_COUNT events, seed: $SEED" && tput sgr0
}

RUNNING_TESTS=false
EVENT_COUNT=15000 #Converts to $1 if passed
SEED="$RANDOM"

android_choose_device
android_device_info "$SELECTED_DEVICE"
update_package_name "$SELECTED_DEVICE"
lock_task_fullscreen "$SELECTED_DEVICE"

case "$1" in #if $1 not number, LOL
    ''|*[!0-9]*) ;; #nothing left to do
    *) EVENT_COUNT="$1" ;;
esac

case "$2" in #if $2 not number, LOL
    ''|*[!0-9]*) ;; #nothing left to do
    *) SEED="$2" ;;
esac

run_test "$SELECTED_DEVICE" "$SEED" "$EVENT_COUNT"