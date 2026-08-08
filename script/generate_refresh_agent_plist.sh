#!/bin/sh

set -eu

template_path="${PROJECT_DIR}/OpenASO/Resources/OpenASORefreshAgent.plist.template"
output_directory="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Library/LaunchAgents"
output_path="${output_directory}/${PRODUCT_BUNDLE_IDENTIFIER}.refresh-agent.plist"

mkdir -p "${output_directory}"
sed \
  -e "s|@BUNDLE_IDENTIFIER@|${PRODUCT_BUNDLE_IDENTIFIER}|g" \
  -e "s|@EXECUTABLE_NAME@|${EXECUTABLE_NAME}|g" \
  "${template_path}" > "${output_path}"

plutil -lint "${output_path}"
