#!/bin/bash
TODAY=$(date +"%d-%m-%Y")
VOICEGATEWAY_NAMESPACE=voicegateway
TARGET_DIR="secrets-backup-${TODAY}"

if [ -d ${TARGET_DIR} ]
then
  echo "target Directory ${TARGET_DIR} already exists, exiting now..."
  exit 0;
fi
echo "Creating Target directory ${TARGET_DIR}"
mkdir ./${TARGET_DIR}
mkdir ./${TARGET_DIR}/${VOICEGATEWAY_NAMESPACE}
echo "Backup secrets of VoiceGateway within ${VOICEGATEWAY_NAMESPACE} namespace"
kubectl -n ${VOICEGATEWAY_NAMESPACE} get --no-headers secrets --field-selector type=Opaque | awk '/voicegateway/{print $1}' | xargs -I {} sh -c "kubectl -n ${VOICEGATEWAY_NAMESPACE} get secret {} -o yaml  > ./${TARGET_DIR}/${VOICEGATEWAY_NAMESPACE}/{}.yaml"
echo "Backup is done. Please store the backup folder somewhere securely since it contains Passwords"