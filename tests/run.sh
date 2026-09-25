#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
export READTRAIL_TEST_DIR="$test_dir"
export XDG_CONFIG_HOME="$test_dir/config"
export XDG_DATA_HOME="$test_dir/data"
export XDG_STATE_HOME="$test_dir/state"
export XDG_CACHE_HOME="$test_dir/cache"
export NVIM_APPNAME=readtrail-test
nvim -u NONE -i NONE --headless -l tests/test.lua
