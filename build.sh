#!/usr/bin/env bash
# This script clones ManageIQ repos, patch them with pending PRS, pushes to a fork,
# and triggers a container image build on DockerCloud

# "Bash strict mode" settings - http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -e          # exit on error (like a normal programming langauge)
set -u          # fail when undefined variables are used
set -o pipefail # prevent errors in a pipeline from being masked

BUILD_TYPE=${1:-unstable}
BUILD_TIME=$(date +%Y%m%d-%H%M)
BRANCH=image-${BUILD_TYPE}
PENDING_PRS=${PWD}/pending-prs-${BUILD_TYPE}.json
BUILD_ID=${BUILD_ID:-}
BASEDIR=${PWD}/manageiq-${BUILD_TYPE}
CORE_REPO=manageiq
GITHUB_ORG=container-mgmt
PODS_TAG_SUFFIX="-${BUILD_TYPE}-${BUILD_TIME}" # suffix for the tag in ManageIQ-pods
if [ "${BUILD_TYPE}" == "unstable" ]; then
    IMAGE_REPO="manageiq-pods"       # in dockerhub
    BASE_BRANCH="master"             # base branch for ManageIQ repos
    PODS_BRANCH="integration-build"  # branch to use for our ManageIQ-pods fork
    PRS_PARAM=""
else
    IMAGE_REPO="manageiq-pods-stable"       # in dockerhub
    BASE_BRANCH="gaprindashvili"            # base branch for ManageIQ repos
    PODS_BRANCH="integration-build-stable"  # branch to use for our ManageIQ-pods fork
    PRS_PARAM="--stable"                    # parameter to pass to the PR management script
fi
LOCAL_REGISTRY=${LOCAL_REGISTRY:-}
PRS_JSON=$(jq -Mc . "${PENDING_PRS}")
SCRIPT_PATH=$(pwd)
COMMITSTR=""
TAG="patched-${BUILD_TYPE}-${BUILD_TIME}"
export TAG  # needs to be exported for use with envsubst later

# Even when push is done with deploy keys, we need username and password
# or access token to avoid API rate limits
set +u # temporarily allow undefined variables
if [ -z "${GIT_USER}" ]; then
    read -p "GitHub username: " -r GIT_USER
fi
if [ -z "${GIT_PASSWORD}" ]; then
    read -p "GitHub password (or token) for ${GIT_USER}:" -sr GIT_PASSWORD
fi
set -u # disallow undefined variables again

# Remove merged PRs from the list to avoid conflicts
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 python2 manageiq_prs.py remove_merged $PRS_PARAM
# Get list of PRs used for this build
LINKS="$(LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 python2 manageiq_prs.py printlinks $PRS_PARAM)"

if [ ! -d "${BASEDIR}" ]; then
    mkdir "${BASEDIR}"
fi
cd "${BASEDIR}"

# Read repo list from the pending PRs json
repos=$(jq "keys[]" -r "${PENDING_PRS}")

for repo in ${repos}; do
    echo -e "\n\n\n** DOING REPO ${repo}**\n----------------------------------------------\n"
    if [ -d "${repo}" ]; then
        echo "${repo} is already cloned, updating"
        pushd "${repo}"
        # Clean up the repo and make sure it's in sync with upstream base branch
        git checkout ${BASE_BRANCH}
        git clean -xdf
        git reset HEAD --hard
        git branch -D ${BRANCH}
        git pull origin ${BASE_BRANCH}
    else
        git clone "https://github.com/ManageIQ/${repo}"
        pushd "${repo}"
        git remote add "${GITHUB_ORG}" "git@github.com:${GITHUB_ORG}/${repo}"
        git checkout ${BASE_BRANCH}
    fi

    # Save the HEAD ref, so we know which upstream commit was the latest
    # when we rolled the build.
    MASTER_HEAD=$(git rev-parse --short HEAD)
    echo "${BASE_BRANCH} is: ${MASTER_HEAD}"
    COMMITSTR="${COMMITSTR}"$'\n'"${repo} ${BASE_BRANCH} HEAD was https://github.com/ManageIQ/${repo}/commit/${MASTER_HEAD}"

    # tag this HEAD to mark it was the HEAD for the current BUILD_TIME
    git tag "head-${BUILD_TIME}"
    # make sure our base branch is up to date with upstream, so the tag would be meaningful
    git push --tags ${GITHUB_ORG} ${BASE_BRANCH}

    #weird bash hack
    string_escaped_repo=\"${repo}\"

    git checkout -b "${BRANCH}"
    if [ "${repo}" == "${CORE_REPO}" ]; then
        # Patch the Gemfile to load plugins from our forks instead of upstream
        envsubst < ../../manageiq-use-forked.patch.in > manageiq-use-forked.patch
        git am --3way manageiq-use-forked.patch
    fi
    for pr in $(jq ".${string_escaped_repo}[]" -r < "${PENDING_PRS}"); do
        git fetch origin "pull/${pr}/head"
        for sha in $(curl -u "${GIT_USER}:${GIT_PASSWORD}" "https://api.github.com/repos/ManageIQ/${repo}/pulls/${pr}/commits" | jq .[].sha -r); do
            git cherry-pick "${sha}"
        done
    done

    echo -e "\n\n\n** PUSHING REPO ${repo}**\n----------------------------------------------\n"
    git tag "${TAG}"
    git push --set-upstream --tags "${GITHUB_ORG}" "${BRANCH}" --force
    echo -e "\n** FINISHED REPO ${repo} **\n---------------------------------------------- \n"
    popd
done

echo "Cloning manageiq-pods..."
if [ -d "manageiq-pods" ]; then
    pushd manageiq-pods
    git checkout ghorg_arg  # FIXME this should be master
    git clean -xdf
    git reset HEAD --hard
    git pull origin master
else
    # FIXME: the clone URL for ManageIQ pods should be changed to upstream
    # once the PR is merged: https://github.com/ManageIQ/manageiq-pods/pull/252
    git clone "https://github.com/elad661/manageiq-pods" -bghorg_arg
    pushd manageiq-pods
    git remote add "${GITHUB_ORG}" "git@github.com:${GITHUB_ORG}/manageiq-pods"
fi
pushd images

echo -e "\nModifying Dockerfiles...\n"

# Copy dockerfiles from master to use as base for modifications
pushd miq-app
cp Dockerfile Dockerfile.orig
popd
pushd miq-app-frontend
cp Dockerfile Dockerfile.orig
popd

# Now checkout the integration-build branch so we can update the dockerfiles
# in a way that keeps their git history

git fetch "${GITHUB_ORG}"
git checkout -B ${PODS_BRANCH}

pushd miq-app
# Note: we modify the URL for the manageiq tarball instead of modifying REF
# because we don't patch manageiq-appliance
sed "s/GHORG=ManageIQ/GHORG=${GITHUB_ORG}/g" < Dockerfile.orig | sed 's/manageiq\/tarball\/${REF}/manageiq\/tarball\/'"${TAG}"'/g' > Dockerfile
echo "Modified miq-app dockerfile"
git diff Dockerfile | cat
git add Dockerfile
popd

pushd miq-app-frontend
# Not setting GHORG here because we don't patch manageiq-ui-service
sed "s/FROM manageiq\/manageiq-pods:backend-latest/FROM containermgmt\/${IMAGE_REPO}:backend${PODS_TAG_SUFFIX}/g" < Dockerfile.orig > Dockerfile
echo "${BUILD_TYPE} build, ${BUILD_TIME} (Jenkins ID: ${BUILD_ID})" > docker-assets/patches.txt
echo "$LINKS" >> docker-assets/patches.txt
echo -e "\nBase refs:\n${COMMITSTR}" >> docker-assets/patches.txt
echo "COPY docker-assets/patches.txt /patches.txt" >> Dockerfile
git diff docker-assets/patches.txt | cat
git diff Dockerfile | cat
git add Dockerfile
git add docker-assets/patches.txt
popd

git commit -F- <<EOF
Automated ${BUILD_TYPE} image build ${BUILD_TIME}
Jenkins ID: ${BUILD_ID}

Using PRs:
${PRS_JSON}

Base refs: ${COMMITSTR}
EOF
# We need two tags (instead of just one) to force the DockerHub automated build
# to build two images from the same repository. It's a bit of a hack, but
# that's what the ManageIQ people do for their builds as well.
echo "pushing backend tag"
git tag "backend${PODS_TAG_SUFFIX}"
git push --force --tags ${GITHUB_ORG} ${PODS_BRANCH}
sleep 15  # HACK: push the backend tag first in hopes DockerHub will build it before building the frontend tag
git tag "frontend${PODS_TAG_SUFFIX}"
echo "pushing frontend tag"
git push --force --tags ${GITHUB_ORG} ${PODS_BRANCH}
echo "Pushed manageiq-pods, 🐋dockerhub/dockercloud should do the rest."
cd "${SCRIPT_PATH}"
if [ ! -z "${DOCKERCLOUD_PASS}" ]; then
    LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 python2 poll_dockercloud.py "${IMAGE_REPO}" "${BUILD_TIME}"
fi

if [ ! -z "${LOCAL_REGISTRY}" ]; then
    echo "Pulling image..."
    docker pull containermgmt/${IMAGE_REPO}
    echo
    echo "Pushing to local registry..."
    echo
    docker tag containermgmt/${IMAGE_REPO} "${LOCAL_REGISTRY}/containermgmt/${IMAGE_REPO}"
    docker tag containermgmt/${IMAGE_REPO}:latest "${LOCAL_REGISTRY}/containermgmt/${IMAGE_REPO}:frontend-latest"
    docker push "${LOCAL_REGISTRY}/containermgmt/${IMAGE_REPO}"
    docker push "${LOCAL_REGISTRY}/containermgmt/${IMAGE_REPO}:frontend-latest"
    echo
    echo "Push complete, deleting local copy"
    echo
    docker rmi containermgmt/${IMAGE_REPO}
fi
echo "Done!"
