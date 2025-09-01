#!/bin/bash

cd "$(dirname "$0")"/.. || exit 1

SIMULATOR_IDS=$(xcrun simctl list devices available | grep -E Booted | sed "s/^[ \t]*//" | tr " " "\n")

REAL_SIMULATOR_ID=
for SIMULATOR_ID in $SIMULATOR_IDS; do
    SIMULATOR_ID=${SIMULATOR_ID//[()]/}
    if [[ $SIMULATOR_ID =~ ^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$ ]]; then
        REAL_SIMULATOR_ID=$SIMULATOR_ID
        break
    fi
done

if [ -z "$REAL_SIMULATOR_ID" ]; then
    echo "No booted simulator found"
    exit 1
fi

BINARY=".theos/obj/iphone_simulator/debug/trollvncserver"
if [ ! -f "$BINARY" ]; then
    BINARY=".theos/obj/iphone_simulator/trollvncserver"
fi

xcrun simctl spawn "$REAL_SIMULATOR_ID" "$BINARY" -C off -U on -O on -M altcmd
