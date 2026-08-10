#!/bin/bash
set -e

echo "Starting GitHub Actions Runner for ${REPO_OWNER}/${REPO_NAME}"

# Get registration token from GitHub API
echo "Obtaining registration token..."
REGISTRATION_TOKEN=$(curl -sX POST \
  -H "Authorization: token ${GITHUB_PAT}" \
  -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/actions/runners/registration-token" \
  | jq -r .token)

if [ -z "$REGISTRATION_TOKEN" ] || [ "$REGISTRATION_TOKEN" = "null" ]; then
  echo "ERROR: Failed to get registration token. Check your GITHUB_PAT and repo permissions."
  exit 1
fi

echo "Configuring runner..."
# Configure the runner
./config.sh \
  --url "https://github.com/${REPO_OWNER}/${REPO_NAME}" \
  --token "${REGISTRATION_TOKEN}" \
  --name "${HOSTNAME}" \
  --work "_work" \
  --labels "azure-container-apps,self-hosted" \
  --unattended \
  --ephemeral \
  --replace

# Cleanup function to deregister runner on exit
cleanup() {
  echo "Removing runner..."
  ./config.sh remove --token "${REGISTRATION_TOKEN}" || true
}
trap cleanup EXIT

echo "Starting runner..."
# Run the runner
./run.sh