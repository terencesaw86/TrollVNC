#!/bin/bash

THEOS="$HOME/theos"
if [ ! -d "$THEOS" ]; then
  THEOS="$GITHUB_WORKSPACE/theos"
fi

export THEOS
export THEOS_PACKAGE_SCHEME=rootless
export THEOS_DEVICE_IP=127.0.0.1
export THEOS_DEVICE_PORT=58422
export THEOS_DEVICE_SIMULATOR=
