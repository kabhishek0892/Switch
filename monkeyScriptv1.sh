#!/bin/bash

############ EXIT TRAP

SCRIPT_LOCATION=$(dirname "$0")
testing=false;
trap 'ctrlc' 1 2 3 6 15

ctrlc()
{
if $testing; then
   adb shell ps | awk '/com\.android\.commands\.monkey/ { system("adb shell kill " $2) }' >/dev/null 2>&1
   if [ "$SILENT" = false ] ; then
      echo
      echo "Monkey shot down! Your device is safe now."
   fi
   if [[ $api -ge 23 ]] ; then #android >=6
      adb shell am task lock stop >/dev/null 2>&1
      if [ "$SILENT" = false ] ; then
         echo "App unlocked from screen."
      fi
   fi
   exit 2 #exit code
else
   exit 2 #exit code
fi
}

android_get_devices_auth_dump(){
  DEVICES_DUMP="$SCRIPT_LOCATION/adb_devices_dump.txt"
  rm -f $DEVICES_DUMP
  adb devices | grep -v "List" >> $DEVICES_DUMP
  if cat "$DEVICES_DUMP" | grep -q unauthorized ; then
    read -r -p $'🚨 Unauthorized Android device detected!\n🔌 Reconnect it, allow USB debugging and press ENTER...'
    android_get_devices_auth_dump
  fi
  if cat "$DEVICES_DUMP" | grep -q offline ; then
    read -r -p $'🚨 Offline Android device detected!\n🔌 Wait until the startup is complete, then press ENTER...'
    android_get_devices_auth_dump
  fi
}

android_get_devices(){
  #Populate array with device ids
  DEVICES=()
  android_get_devices_auth_dump
  for LINE in $(cat $DEVICES_DUMP | awk '{print $1}')
  do
    DEVICE=$(echo "$LINE" | awk '{print $1}')
    DEVICES+=("$DEVICE")
  done
}

android_check_connected(){
  android_get_devices
  #No device connected
  if [ ${#DEVICES[@]} -eq 0 ]
  then
    echo "❌ No Android devices detected"
    exit 1
  fi
}

############ PRE-TEST CHECKS
check_device_count()
{
android_check_connected

#check if more devices connected
if ([[ $(adb devices -l | wc -l) -gt 3 ]]); then
   echo "More than one device detected, connect only one to continue..."
fi
while ([[ $(adb devices -l | wc -l) -gt 3 ]]); do
   sleep 1;
done
}
check_display()
{
check_device_count

TRY=0;
if ([[ $(adb shell dumpsys window displays | grep mCurrentFocus | cut -d'/' -f1 | rev | cut -d' ' -f1 | rev) == *"StatusBar}"* || $(adb shell dumpsys window displays | grep mCurrentFocus | cut -d'/' -f1 | rev | cut -d' ' -f1 | rev) == *"mCurrentFocus=null"* ]]); then
   if [ "$SILENT" = false ] ; then
      echo "Waking up device."
   fi
   adb shell input keyevent KEYCODE_POWER
   adb shell input keyevent 82
fi
while ([[ $(adb shell dumpsys window displays | grep mCurrentFocus | cut -d'/' -f1 | rev | cut -d' ' -f1 | rev) == *"StatusBar}"* || $(adb shell dumpsys window displays | grep mCurrentFocus | cut -d'/' -f1 | rev | cut -d' ' -f1 | rev) == *"mCurrentFocus=null"*  ]]); do
   if [ $TRY -le 3 ]; then
      ((TRY++));
      adb shell input keyevent KEYCODE_POWER
      adb shell input keyevent 82
      sleep 1;
   else
      echo -ne "Unlocking failed, waiting for manual unlock...\r"
   fi
done
if [ $TRY -ge 3 ]; then
   echo
fi
}

check_device()
{
check_device_count

#check android api ver
api=$(adb shell getprop ro.build.version.sdk);
api=${api//[!0-9]/};
if ! ([[ $api -ge 21 ]]); then
   if [ "$SILENT" = false ] ; then
      echo "Sorry this script supports only API 21+"
      echo "Aborting..."
      echo
   fi
   exit 2 #exit code
fi

#check if messenger is installed --> O/P 0 means Not installed
if ([[ $(adb shell pm list packages | grep orca | wc -l) -ge 1 ]]); then
   if [ "$SILENT" = false ] ; then
      echo "Messenger package detected, it is advised to turn off notifications."
      echo -ne "Press ENTER to continue..."
      read
   fi
fi

#check if display is on
check_display

#get app package name
app=$(adb shell dumpsys window displays | grep mCurrentFocus | cut -d'/' -f1 | rev | cut -d' ' -f1 | rev)

#check if system package
if ([[ $(adb shell dumpsys window displays | grep mCurrentFocus | cut -d'/' -f1 | rev | cut -d' ' -f1 | rev) == *"android"* ]]); then
   echo "App appears to be system package, open your app to continue...";
   while ([[ $(adb shell dumpsys window windows | grep mCurrentFocus | cut -d'/' -f1 | rev | cut -d' ' -f1 | rev) == *"android"* ]]); do
      sleep 2;
   done
   sleep 3;
   app=$(adb shell dumpsys window displays | grep mCurrentFocus | cut -d'/' -f1 | rev | cut -d' ' -f1 | rev)
fi

#check if launcher
if ([[ $(adb shell dumpsys window displays | grep mCurrentFocus | cut -d'/' -f1 | rev | cut -d' ' -f1 | rev) == *"launcher"* ]]); then
   echo -n "App appears to be launcher, press ENTER to continue...";
   read force;
   if [[ $force == *"n"* ]]; then
      if [ "$SILENT" = false ] ; then
         echo "Aborting...";
      fi
      exit 0 #exit code
   else
      app=$(adb shell dumpsys window displays | grep mCurrentFocus | cut -d'/' -f1 | rev | cut -d' ' -f1 | rev)
   fi
fi

#echo package name of tested app
if [ "$SILENT" = false ] ; then
   echo "Foreground app package name: "$app
fi
}

############ RUN TEST

run_test()
{
#make folder if it doesnt exist
if ! [ -d $DIRECTORY ] ; then
   mkdir $DIRECTORY >/dev/null 2>&1
   if [ $? -ne 0 ]; then
      if [ "$SILENT" = false ] ; then
         echo 'Cannot create directory "'$DIRECTORY'"'
         echo 'Permission denied, aborting...'
      fi
      exit 1 #exit code
   fi
fi

#check/set number input events
events=0
if [ -z "$1" ] || (( $1<1 )); then
   until [[ $events =~ ^-?[0-9]+$ ]] && [ $events -gt 0 ]; do
      echo -n "Please specify number of input events: ";
      read events;
   done
else
   if [ "$SILENT" = false ] ; then
      echo "Input events incoming: "$1;
   fi
   events=$1;
fi

#set seed
if ! [ -z "$2" ]; then
   if [ "$SILENT" = false ] ; then
      echo "Seed set to: "$2;
   fi
   seed=$2
else
   seed=$RANDOM
   if [ "$SILENT" = false ] ; then
      echo "Setting random seed: "$seed
   fi
fi


#checks passed
logname="$app-`date +%Y-%m-%d-%H-%M-%S`.log"

#create log
echo "Android APP stress test "$ver >> $DIRECTORY/$logname
echo "Test with seed "$seed "and "$events" input events started at: `date +%Y-%m-%d-%H-%M-%S`" >> $DIRECTORY/$logname
echo "---------------------------" >> $DIRECTORY/$logname

#lock screen
task_id=$(adb shell dumpsys activity | grep mFocusedActivity | rev) #get focused activity info and reverse it
set $task_id #breaks task_id into $1 $2 ...
task_id=$1 #saves $1 into task_id
task_id=$(echo $task_id | rev) # reverse string back
task_id=${task_id//[!0-9]/} #strip non numeric chars from task_id

#api specific locking
if [[ $api -ge 23 ]] ; then #android >=6
   adb shell am task lock $task_id >/dev/null 2>&1 #lock current app to prevent monkey escape
   adb shell input tap 865 1620 #ugly hardcoded tap, substitute by (x,y) of your confirm button
elif [[ $api -eq 22 ]] ; then #android 5.1
   adb shell am lock-task $task_id >/dev/null 2>&1 #lock current app to prevent monkey escape
   adb shell input tap 865 1620 #ugly hardcoded tap, substitute by (x,y) of your confirm button
elif [[ $api -eq 21 ]] ; then #android 5
   adb shell am lock-task $task_id >/dev/null 2>&1 #lock current app to prevent monkey escape
   adb shell input keyevent 22
   adb shell input keyevent 22
   adb shell input keyevent 66
fi

if [ "$SILENT" = false ] ; then
   echo "App locked to screen."
fi

#run test
if [ "$SILENT" = false ] ; then
   echo "Testing..."
fi
testing=true;

adb shell monkey -p $app -s $seed -v $events
#--monitor-native-crashes -- to add and check

#api specific unlocking
if [[ $api -ge 23 ]] ; then #android >=6
   adb shell am task lock stop >/dev/null 2>&1
   if [ "$SILENT" = false ] ; then
      echo "App unlocked from screen."
   fi
elif [[ $api -eq 22 || $api -eq 21 ]] ; then #android 5 and 5.1
   #NO UNLOCK FOR android<6.0
   if [ "$SILENT" = false ] ; then
      echo "No app unlock for API 21 and 22 for now."
      echo "Unlock app by holding BACK and RECENTS buttons."
   fi
fi

#check test result
if grep -q "CRASH" $DIRECTORY/$logname ; then
   if [ "$SILENT" = false ] ; then
      echo 'App crashed, test FAILED!'
      echo "Log saved to $DIRECTORY: CRASH-"$logname
      echo "---------------------------"
   fi
   echo "---------------------------" >> $DIRECTORY/$logname
   echo "App was destroyed by monkey and crashed!" >> $DIRECTORY/$logname
   mv $DIRECTORY/$logname $DIRECTORY/CRASH-$logname
   return 1 #exit code from run_test function

elif grep -q "RESPONDING" $DIRECTORY/$logname ; then
   if [ "$SILENT" = false ] ; then
      echo 'App frozen, test FAILED!'
      echo "Log saved to $DIRECTORY: FREEZE-"$logname
      echo "---------------------------"
   fi
   echo "---------------------------" >> $DIRECTORY/$logname
   echo "App was destroyed by monkey and stopped responding!" >> $DIRECTORY/$logname
   mv $DIRECTORY/$logname $DIRECTORY/FREEZE-$logname

   return 1 #exit code from run_test function

elif grep -q "Events" $DIRECTORY/$logname ; then
   if [ "$SILENT" = false ] ; then
      echo "App survived, test PASSED!">>monkey_log.txt
   fi
   echo "---------------------------" >> $DIRECTORY/$logname
   echo "App survived monkey madness!" >> $DIRECTORY/$logname

   rm $DIRECTORY/$logname
   if [ -d $DIRECTORY ] ; then #delete log directory if its empty and test passed
      if [ $(ls $DIRECTORY | wc -l) -lt 1 ] ; then
         rm -rf $DIRECTORY
      fi
   fi
   if [ "$SILENT" = false ] ; then
      echo "---------------------------"
   fi
   return 0 #exit code from run_test function

else
   if [ "$SILENT" = false ] ; then
      echo "Monkey was killed in action!"
      echo "Log saved to $DIRECTORY: KILLED-"$logname
      echo "---------------------------"
   fi
   echo "---------------------------" >> $DIRECTORY/$logname
   echo "Monkey was killed in action!" >> $DIRECTORY/$logname
   mv $DIRECTORY/$logname $DIRECTORY/KILLED-$logname

   return 2 #exit code from run_test function
fi
}

############ TEST LOOP

run_loop()
{
#check/set number of loops
loops=0
if [ -z "$1" ] || (( $1<1 )) ; then
   until [[ $loops =~ ^-?[0-9]+$ ]] && [ $loops -gt 0 ]; do
      echo -n "Please specify number of tests: ";
      read loops;
   done
else
   if [ "$SILENT" = false ] ; then
      echo "Test will run $1x.";
   fi
   loops=$1;
fi

#check/set number input events
events=0
if [ -z "$2" ] || (( $2<1 )); then
   until [[ $events =~ ^-?[0-9]+$ ]] && [ $events -gt 0 ]; do
      echo -n "Please specify number of input events: ";
      read events;
   done
else
   if [ "$SILENT" = false ] ; then
      echo "Each test will include $2 input events.";
   fi
   events=$2;
fi

#run loop
for i in $(seq 1 $loops); do
   if [ "$SILENT" = false ] ; then
      echo "Restarting $app."
   fi
   adb shell am force-stop $app >/dev/null 2>&1 #kill app to have fresh start
   adb shell monkey -p $app -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1  #start app
   #wait for $app to appear
   sec=0;
   until [ $(adb shell dumpsys window windows | grep mCurrentFocus | cut -d'/' -f1 | rev | cut -d' ' -f1 | rev) == $app ] ; do
      ((sec++)) ;
      if [ "$SILENT" = false ] ; then
         echo -ne "Waiting for launch $sec seconds..." "\r" ;
      fi
      sleep 1 ;
   done
   #blaze that
   if [ "$SILENT" = false ] ; then
      echo
      echo "---------------------------";
      echo "Running test #"$i
   fi
   run_test $events
done

#show results
if [ "$SILENT" = false ] ; then
   echo $loops "tests finished!"
fi
if [ -d $DIRECTORY ] && [ $(ls $DIRECTORY | grep log | wc -l) -gt 0 ]; then
   crashcount=$(ls $DIRECTORY | grep CRASH | wc -l);
   freezecount=$(ls $DIRECTORY | grep FREEZE | wc -l);
   killcount=$(ls $DIRECTORY | grep -v 'FREEZE\|CRASH\|old' | wc -l);
   if [ "$SILENT" = false ] ; then
      if [ $crashcount -gt 0 ] ; then echo "App crashed: "$crashcount"x"; fi
      if [ $freezecount -gt 0 ] ; then echo "App freezed: "$freezecount"x"; fi
      if [ $killcount -gt 0 ] ; then echo "Monkey killed: "$killcount"x"; fi
   fi
   survives=$((loops - crashcount - freezecount - killcount))
   if [ "$SILENT" = false ] ; then
      echo "App survived: "$survives"x"
      echo "Logs from failed tests are located at $DIRECTORY"
      echo
   fi
else
   survives=$loops
   if [ "$SILENT" = false ] ; then
      echo "App survived them all!"
      echo
   fi
fi

#exit code from run_loop function
if [ $survives -lt $loops ]; then
   return 1
else
   return 0
fi

}

############ RUNTIME
SILENT=false;

#Check if args contain QUIET
for arg in "$@"; do
   if ([[ $arg == *"--quiet"* || ${arg:1:1} == *"q"* ]]); then
      SILENT=true;
   fi
done

#nice intro
if [ "$SILENT" = false ] ; then
   echo
   echo "Monkey Madness - stress test";
   echo "---------------------------";
fi
check_display

#Process arguments
arg1=0;
#get current running app
app=$(adb shell dumpsys window windows | grep mCurrentFocus | cut -d'/' -f1 | rev | cut -d' ' -f1 | rev)
DIRECTORY=$PWD/$app;

#OTHER ARGUMENTS
for arg in "$@"; do
   if [[ $arg =~ ^-?[0-9]+$ ]]; then #Arg is number
      if [ $arg1 -gt 0 ]; then
         arg2=$arg;
      else
         arg1=$arg;
      fi
   else #Arg is string
      #Arg contain INSTALL
      if ([[ $arg == *"--install="* || ${arg:1:2} == *"i="* ]]); then
         #Check if config exists
         if [ ! -f monkey_madness.conf ]; then
            if [ "$SILENT" = false ] ; then
               echo 'File "monkey_madness.conf" not found! Aborting...';
            fi
            exit 2 #exit code
         else
            AAPT_PATH=$(cat monkey_madness.conf | grep AAPT_PATH | sed 's/^[^=]*=//');
         fi
         #Check if  aapt exists
         if [ ! -f $AAPT_PATH/aapt ]; then
            if [ "$SILENT" = false ] ; then
               echo 'File "aapt" not found at "'$AAPT_PATH'"! Aborting...';
            fi
            exit 2 #exit code
         fi
         APK=${arg#*=};
         if [ -f $APK ];then
            if [ "$SILENT" = false ] ; then
               echo "Installing $APK"
            fi
            adb install -rtdg $APK >/dev/null 2>&1
            check_display
            #package name from .apk
            PACKAGE_NAME=$($AAPT_PATH/aapt dump badging $APK | grep package:\ name);
            PACKAGE_NAME=$(echo $PACKAGE_NAME | sed 's/^[^'\'']*'\''//');
            PACKAGE_NAME=$(echo $PACKAGE_NAME | sed 's/'\''.*//');
            adb shell monkey -p $PACKAGE_NAME -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
            #wait for $app to appear
            sec=0;
            until [ $(adb shell dumpsys window windows | grep mCurrentFocus | cut -d'/' -f1 | rev | cut -d' ' -f1 | rev) == $PACKAGE_NAME ] ; do
               ((sec++)) ;
               if [ "$SILENT" = false ] ; then
                  echo -ne "Waiting for launch $sec seconds..." "\r" ;
               fi
               sleep 1 ;
            done
            if [ "$SILENT" = false ] ; then
               echo
            fi
            app=$PACKAGE_NAME;
         else
            if [ "$SILENT" = false ] ; then
               echo 'File "'$APK'" does not exist! Aborting...'
            fi
            exit 2 #exit code
         fi
      #Arg contain LOOP
      elif ([[ $arg == *"--loop"* || ${arg:1:1} == *"l"* ]]); then
         LOOP=true;
      fi
      #Arg contain directory
      if ([[ $arg == *"--output="* || ${arg:1:2} == *"o="* ]]); then
         DIRECTORY=${arg#*=};
         if [ -d $DIRECTORY ];then
            DIRECTORY=$DIRECTORY"/"$app;
         else
            if [ "$SILENT" = false ] ; then
               echo 'Directory "'$DIRECTORY'" does not exist! Aborting...'
            fi
            exit 2 #exit code
         fi
      fi
   fi
done

##Check device
check_device

#Args contain CLEAR DATA
for arg in "$@"; do
   if ([[ $arg == *"--clear"* || ${arg:1:1} == *"c"* ]]); then
      if [ "$SILENT" = false ] ; then
         echo "Cleared data of $app";
      fi
      adb shell pm clear $app >/dev/null 2>&1
      adb shell monkey -p $app -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
      #wait for $app to appear
      sec=0;
      until [ $(adb shell dumpsys window windows | grep mCurrentFocus | cut -d'/' -f1 | rev | cut -d' ' -f1 | rev) == $app ] ; do
         ((sec++)) ;
         if [ "$SILENT" = false ] ; then
            echo -ne "Waiting for launch $sec seconds..." "\r" ;
         fi
         sleep 1 ;
      done
      if [ "$SILENT" = false ] ; then
         echo
      fi
   fi
done

#move old logs to old/
if [ -d $DIRECTORY ] && [ $(ls $DIRECTORY | grep log | wc -l) -gt 0 ]; then
   if ! [ -d $DIRECTORY/old ] ; then #make folder if it doesnt exist
      mkdir $DIRECTORY/old
   fi
   if [ "$SILENT" = false ] ; then
      echo "Moving old logs to $DIRECTORY/old"
   fi
   mv $DIRECTORY/*.log $DIRECTORY/old/
fi

#Start loop if arg contain loop
if [ "$LOOP" = true ]; then
   run_loop $arg1 $arg2
else
   run_test $arg1 $arg2
fi