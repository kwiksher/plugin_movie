#!/bin/bash

path=`dirname $0`

OUTPUT_DIR=$1
TARGET_NAME=plugin_movie
OUTPUT_SUFFIX=dylib
CONFIG=Release

#
# Checks exit value for error
#
checkError() {
    if [ $? -ne 0 ]
    then
        echo "Exiting due to errors (above)"
        exit -1
    fi
}

#
# Canonicalize relative paths to absolute paths
#
pushd $path > /dev/null
dir=`pwd`
path=$dir
popd > /dev/null

if [ -z "$OUTPUT_DIR" ]
then
    OUTPUT_DIR=.
fi

# pushd below silently falls back to the cwd when this is missing, which used
# to drop the dylib into whatever directory the caller happened to be in.
if [ ! -d "$OUTPUT_DIR" ]
then
    mkdir -p "$OUTPUT_DIR"
fi

pushd $OUTPUT_DIR > /dev/null
dir=`pwd`
OUTPUT_DIR=$dir
popd > /dev/null

echo "OUTPUT_DIR: $OUTPUT_DIR"

# Let CI (and anyone with Corona Native in a non-default location) point the
# build at a specific Corona tree. Falls back to the xcconfig default.
XCODEBUILD_ARGS=()
if [ -n "${CORONA_ROOT:-}" ]; then
    XCODEBUILD_ARGS+=("CORONA_ROOT=$CORONA_ROOT")
fi

xcodebuild -project "$path/Plugin.xcodeproj" -configuration $CONFIG clean \
    ${XCODEBUILD_ARGS[@]+"${XCODEBUILD_ARGS[@]}"}
checkError

xcodebuild -project "$path/Plugin.xcodeproj" -configuration $CONFIG \
    ${XCODEBUILD_ARGS[@]+"${XCODEBUILD_ARGS[@]}"}
checkError

cp "$path/build/Release/$TARGET_NAME.$OUTPUT_SUFFIX" "$OUTPUT_DIR"
