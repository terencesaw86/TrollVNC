#!/bin/bash

set -e

# shellcheck disable=SC1091
source tools/bootstrap.sh
FINALPACKAGE=1 gmake clean package

# shellcheck disable=SC1091
source tools/default.sh
FINALPACKAGE=1 gmake clean package

# shellcheck disable=SC1091
source tools/rootless.sh
FINALPACKAGE=1 gmake clean package

# shellcheck disable=SC1091
source tools/roothide.sh
FINALPACKAGE=1 gmake clean package
