#!/bin/bash

# We can't test that concourse-up will update itself to a latest release without publishing a new release
# Instead we will test that if we publish a non-existant release, the self-update will revert back to a known release

# shellcheck disable=SC1091
source concourse-up/ci/tasks/lib/verbose.sh

# shellcheck disable=SC1091
source concourse-up/ci/tasks/lib/trap.sh

# shellcheck disable=SC1091
source concourse-up/ci/tasks/lib/pipeline.sh

[ "$VERBOSE" ] && { handleVerboseMode; }

set -eu

deployment="systest-update-$RANDOM"

set +u

trapDefaultCleanup

set -u

cp release/concourse-up-linux-amd64 ./cup-old
cp "$BINARY_PATH" ./cup-new
chmod +x ./cup-*

echo "DEPLOY OLD VERSION"

./cup-old deploy $deployment

# Wait for previous deployment to finish
# Otherwise terraform state can get into an invalid state
# Also wait to make sure the BOSH lock is not taken before
# starting deploy
echo "Waiting for 10 minutes to give old deploy time to settle"
sleep 600

eval "$(./cup-old info --env $deployment)"
config=$(./cup-old info --json $deployment)
domain=$(echo "$config" | jq -r '.config.domain')

echo "Waiting for bosh lock to become available"
wait_time=0
until [[ $(bosh locks --json | jq -r '.Tables[].Rows | length') -eq 0 ]]; do
  (( ++wait_time ))
  if [[ $wait_time -ge 10 ]]; then
    echo "Waited too long for lock" && exit 1
  fi
  printf '.'
  sleep 60
done
echo "Bosh lock available - Proceeding"

echo "UPDATE TO NEW VERSION"
# export SELF_UPDATE=true

./cup-new deploy $deployment

echo "Waiting for 30 seconds to let detached upgrade start"
sleep 30

echo "Waiting for update to complete"
wait_time=0
# shellcheck disable=SC2091
until $(curl -skIfo/dev/null "https://$domain"); do
  (( ++wait_time ))
  if [[ $wait_time -ge 10 ]]; then
    echo "Waited too long for deployment" && exit 1
  fi
  printf '.'
  sleep 30
done
echo "Update complete - Proceeding"

sleep 60

config=$(./cup-new info --json $deployment)
domain=$(echo "$config" | jq -r '.config.domain')
username=$(echo "$config" | jq -r '.config.concourse_username')
password=$(echo "$config" | jq -r '.config.concourse_password')
echo "$config" | jq -r '.config.concourse_ca_cert' > generated-ca-cert.pem

cert="generated-ca-cert.pem"
manifest="$(dirname "$0")/hello.yml"
job="hello"

set +u
assertPipelineIsSettableAndRunnable "$cert" "$domain" "$username" "$password" "$manifest" "$job"
