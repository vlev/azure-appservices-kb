#!/usr/bin/env bash

#
# This script waits for the main process (with pid == $GLOBAL_PID_MAIN) to exit.
# NOTE: Simply calling this script will not work. It has to be sourced into the calling script.
# This is because $GLOBAL_PID_MAIN has to be a child process of this shell, otherwise waiting for it fails.
# Usage: source ./wait_for_main_process.sh
#

echo Waiting for main process to exit. GLOBAL_PID_MAIN=$GLOBAL_PID_MAIN

while [ -d /proc/$GLOBAL_PID_MAIN ] # Check if the process is running
do
    echo Waiting for GLOBAL_PID_MAIN == $GLOBAL_PID_MAIN
    wait $GLOBAL_PID_MAIN # Note: This will exit when any signal is delivered to this process, so we loop waiting for the process to actually exit
    echo Wait for pid == $GLOBAL_PID_MAIN either returned successfully or was interrupted due to a signal $GLOBAL_PID_MAIN
done

echo Done waiting for main process. GLOBAL_PID_MAIN=$GLOBAL_PID_MAIN.
