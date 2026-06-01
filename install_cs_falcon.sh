#!/bin/zsh

# Download and install the n-1 version of crowdstrike falcon for macOS. macOS 12+ only.

baseUrl='https://api.us-2.crowdstrike.com'

CLIENT_ID='{your_client_id}'
CLIENT_SECRET='{your_client_secret}'

osversMajor=$(sw_vers -productVersion | awk -F. '{print $1}')

appName="Falcon.app"
appPath="/Applications/${appName}"
appProcessName="com.crowdstrike.falcon.Agent"
pkgName="FalconSensorMacOS.MaverickGyr.pkg"

cleanup () {
  if [[ -f "${tmpDir}/${pkgName}" ]]; then
    if rm -f "${tmpDir}/${pkgName}"; then
      echo "Removed file ${tmpDir}/${pkgName}"
    fi
  fi
  if [[ -d "${tmpDir}" ]]; then
    if rm -R "${tmpDir}"; then
      echo "Removed directory ${tmpDir}"
    fi
  fi
}

createTmpDir () {
  if [ -z ${tmpDir+x} ]; then
    tmpDir=$(mktemp -d)
    echo "Temp dir set to ${tmpDir}"
  fi
}

processCheck () {
  if pgrep -x "${appProcessName}" > /dev/null; then
    echo "${appProcessName} is currently running"
    echo "Aborting install"
    exit 0
  else
    echo "${appProcessName} not currently running"
  fi
}

tryDownload () {
  if curl -Ls -H "Authorization: Bearer ${accessToken}" \
    "${baseUrl}/sensors/entities/download-installer/v2?id=${sensor_sha256}" -o "${tmpDir}/${pkgName}"; then
    echo "Download successful"
    tryDownloadState=1
  else
    echo "Download unsuccessful"
    tryDownloadCounter=$((tryDownloadCounter+1))
  fi
}

versionCheck () {
  if [[ -d "${appPath}" ]]; then
    echo "${appName} version is $(defaults read "${appPath}"/Contents/Info.plist CFBundleShortVersionString)"
    versionCheckStatus=1
  else
    echo "${appName} not installed"
    versionCheckStatus=0
  fi
}

# Start

# List version
versionCheck

accessTokenData=$(curl -s -X POST -d "client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}" ${baseUrl}/oauth2/token)
#echo $accessTokenData

if [[ ${osversMajor} -ge 15 ]]; then
  accessToken=$(/usr/bin/jq -r '.access_token' <<< "${accessTokenData}")
else
  accessToken=$(/usr/bin/plutil -extract access_token raw -o - - <<< "${accessTokenData}")
fi
#echo $accessToken

sensorVersions=$(curl -s -X GET -H "Authorization: Bearer ${accessToken}" -H 'Content-Type: application/json' \
"$baseUrl/policy/combined/sensor-update-builds/v1?platform=mac&stage=prod")

# 2025-02-21 Crowdstrike added " (LTS)" to the end of the sensor version for LTS builds. Now grabbing everything before a space.
if [[ ${osversMajor} -ge 15 ]]; then
  sensorVersion=$(/usr/bin/jq -r 'first(.resources[] | select(.build|test("\\|n-1\\|")) | .sensor_version)' <<< "${sensorVersions}" | awk '{print $1}')
else
  #sensorVersion=$(grep -A1 -E '\"build\":.+\|n-1\|' <<< "${sensorVersions}" | tail -n 1 | grep -E '\"sensor_version\"' | awk -F':' '{print $NF}' | awk -F'"' '{print $2}')
  sensorCount=$(($(/usr/bin/plutil -extract "resources" raw -o - - <<< "${sensorVersions}")-1))
  for sensor in {0.."${sensorCount}"}; do
    sensorCandidate=$(/usr/bin/plutil -extract "resources"."${sensor}".build raw -o - - <<< "${sensorVersions}")
    if [[ "${sensorCandidate}" =~ '\|n-1\|' ]]; then
      sensorVersion=$(/usr/bin/plutil -extract "resources"."${sensor}".sensor_version raw -o - - <<< "${sensorVersions}" | awk '{print $1}')
      continue
    fi
  done
fi

echo "N-1 sensor version: ${sensorVersion}"

sensors=$(curl -s -X GET -H "Authorization: Bearer ${accessToken}" -H 'Content-Type: application/json' \
"${baseUrl}/sensors/combined/installers/v2?filter=platform%3A%22mac%22%2Bos%3A%22macOS%22%2Bversion%3A%22${sensorVersion}%22")

if [[ ${osversMajor} -ge 15 ]]; then
  sensor_sha256=$(/usr/bin/jq -r '.resources[0] | .sha256' <<< "${sensors}")
else
  sensor_sha256=$(/usr/bin/plutil -extract "resources".0."sha256" raw -o - - <<< "${sensors}")
fi
echo "N-1 sensor sha256: ${sensor_sha256}"

# Download pkg file into tmp dir (60 second timeouet)
tryDownloadState=0
tryDownloadCounter=0
while [[ ${tryDownloadState} -eq 0 && ${tryDownloadCounter} -le 60 ]]; do
  processCheck
  createTmpDir
  tryDownload
  sleep 1
done

 # Install package
echo "Starting install"
installer -pkg "${tmpDir}/${pkgName}" -target /

# Remove tmp dir and downloaded pkg package
cleanup

# List version and exit with error code if not found
versionCheck
if [[ ${versionCheckStatus} -eq 0 ]]; then
  exit 1
fi
