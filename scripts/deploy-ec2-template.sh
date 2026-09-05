#!/usr/bin/env bash
set -euo pipefail

# MARK: - Task list
# [x] Validate the CloudFormation template
# [x] Deploy the HTTPS-only EC2 infrastructure

STACK_NAME="${1:-titty-backend}"
REGION="${AWS_REGION:-ca-central-1}"
PARAMETERS_FILE="${2:-infrastructure/parameters.example.json}"

aws cloudformation validate-template \
  --region "${REGION}" \
  --template-body file://infrastructure/ec2-cloudformation.yaml >/dev/null

aws cloudformation deploy \
  --region "${REGION}" \
  --stack-name "${STACK_NAME}" \
  --template-file infrastructure/ec2-cloudformation.yaml \
  --parameter-overrides "file://${PARAMETERS_FILE}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset

aws cloudformation describe-stacks \
  --region "${REGION}" \
  --stack-name "${STACK_NAME}" \
  --query 'Stacks[0].Outputs' \
  --output table
