#!/usr/bin/env bash
# This script runs on the "build host" to build the actual container image,
# and push it to the local & global docker registries.

# "Bash strict mode" settings - http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -e          # exit on error (like a normal programming langauge)
set -u          # fail when undefined variables are used
set -o pipefail # prevent errors in a pipeline from being masked

IMAGE_REPO=${1:-}
PODS_TAG_SUFFIX=${2:-}
LOCAL_REGISTRY=${3:-}
LOCAL_REGISTRY_PASS=${4:-}
DOCKERCLOUD_USER=${5:-}
DOCKERCLOUD_PASS=${6:-}

echo
echo "======== Starting build ========"
echo

docker build -t "containermgmt/${IMAGE_REPO}:backend${PODS_TAG_SUFFIX}" -t "containermgmt/${IMAGE_REPO}:backend-latest" images/miq-app
docker build -t "containermgmt/${IMAGE_REPO}:frontend${PODS_TAG_SUFFIX}" -t "containermgmt/${IMAGE_REPO}:frontend-latest" images/miq-app-frontend
echo
echo "======== Build complete ========"
echo
docker tag "containermgmt/${IMAGE_REPO}:frontend${PODS_TAG_SUFFIX}" "${LOCAL_REGISTRY}/containermgmt/${IMAGE_REPO}:frontend${PODS_TAG_SUFFIX}"
docker tag "containermgmt/${IMAGE_REPO}:frontend-latest" "${LOCAL_REGISTRY}/containermgmt/${IMAGE_REPO}:frontend-latest"
docker login -u unused -p "${LOCAL_REGISTRY_PASS}" "${LOCAL_REGISTRY}"
docker push "${LOCAL_REGISTRY}/containermgmt/${IMAGE_REPO}:frontend${PODS_TAG_SUFFIX}"
docker push "${LOCAL_REGISTRY}/containermgmt/${IMAGE_REPO}:frontend-latest"
echo
echo "======== Push to local complete ========"
echo
docker login -u "${DOCKERCLOUD_USER}" -p "${DOCKERCLOUD_PASS}"
docker tag "containermgmt/${IMAGE_REPO}:frontend${PODS_TAG_SUFFIX}" "docker.io/containermgmt/${IMAGE_REPO}:frontend${PODS_TAG_SUFFIX}"
docker tag "containermgmt/${IMAGE_REPO}:frontend-latest" "docker.io/containermgmt/${IMAGE_REPO}:frontend-latest"
docker push "docker.io/containermgmt/${IMAGE_REPO}:frontend${PODS_TAG_SUFFIX}"
docker push "docker.io/containermgmt/${IMAGE_REPO}:frontend-latest"
echo
echo "======== Push to docker.io complete ========"
echo
docker rmi $(docker images --no-trunc | grep "${IMAGE_REPO} " | awk '{print $3}' | xargs -n1 | sort -u | xargs)

echo
echo "======== DONE ========"
echo
