#!/bin/bash
set -euo pipefail

export AWS_DEFAULT_REGION=us-east-1

EXTRA_REGIONS=(
	us-east-2
	us-west-1
	us-west-2
	eu-west-1
	eu-west-2
	eu-central-1
	ap-northeast-1
	ap-northeast-2
	ap-southeast-1
	ap-southeast-2
	ap-south-1
	sa-east-1
)

VERSION=$(git describe --tags --candidates=1)
BASE_BUCKET=buildkite-lambdas
BUCKET_PATH="ec2-agent-scaler"

if [[ "${1:-}" == "release" ]] ; then
  BUCKET_PATH="${BUCKET_PATH}/v${VERSION}"
else
  BUCKET_PATH="${BUCKET_PATH}/builds/${BUILDKITE_BUILD_NUMBER}"
fi

echo "~~~ :buildkite: Buildking Lambda"
make ec2-agent-scaler.zip

echo "--- :s3: Uploading lambda to ${BASE_BUCKET}/${BUCKET_PATH}/ in ${AWS_DEFAULT_REGION}"
aws s3 cp --acl public-read ec2-agent-scaler.zip "s3://${BASE_BUCKET}/${BUCKET_PATH}/handler.zip"

for region in "${EXTRA_REGIONS[@]}" ; do
	bucket="${BASE_BUCKET}-${region}"
	echo "--- :s3: Copying files to ${bucket}"
	aws --region "${region}" s3 cp --acl public-read "s3://${BASE_BUCKET}/${BUCKET_PATH}/handler.zip" "s3://${bucket}/${BUCKET_PATH}/handler.zip"
done
