#!/usr/bin/env bash
# Deploy dev-caddie for the Gemini Live Agent Challenge hackathon.
# Identical to deploy_dev_caddie.sh but stamps the submission label.
# Usage: ./deploy_gemini_live_hackathon.sh
set -euo pipefail

SERVICE_NAME="dev-caddie-hackathon"
REGION="us-central1"
PROJECT_ID="steel-earth-470201-g1"
IMAGE_NAME="gcr.io/${PROJECT_ID}/${SERVICE_NAME}"
SERVICE_ACCOUNT="dev-caddie-sa@steel-earth-470201-g1.iam.gserviceaccount.com"
DATASET_ID="content_intelligence"
LLM_DATASET_ID="llm_observability"
GCS_BUCKET_NAME="content-intelligence-media-${PROJECT_ID}"
ADMIN_API_KEY_SECRET_NAME="ADMIN_API_KEY"
DAILY_BUDGET_USD="2.00"
MAX_REQUESTS_PER_IP="10"
RATE_LIMIT_NS="glhackathon"
VACATION_MODE="false"
VACATION_END_DATE=""
CONTENT_API_BASE="https://dev-caddie-hackathon-197949782351.us-central1.run.app"
BOT_START_URL="http://10.0.1.24:8081"
BOT_START_ORIGIN="https://dev-caddie-hackathon-197949782351.us-central1.run.app"
VPC_NETWORK="content-intelligence-vpc"
VPC_SUBNET="content-intelligence-subnet"
VPC_EGRESS="all-traffic"
CPU_ALWAYS_ALLOCATED="true"
REQUEST_TIMEOUT="600s"
CREATE_VPC_SUBNET="true"
CREATE_CLOUD_NAT="true"
CLOUD_ROUTER_NAME="cloud-run-router"
CLOUD_NAT_NAME="cloud-run-nat"
HACKATHON_LABEL="dev-tutorial=gemini-live-agent-challenge"

echo "=== Dev Caddie - Gemini Live Agent Challenge Deployment ==="
echo "Service:  ${SERVICE_NAME}"
echo "Label:    ${HACKATHON_LABEL}"
echo "Image:    ${IMAGE_NAME}:latest"
echo ""

echo "Building and pushing image with cache..."
gcloud builds submit --config cloudbuild.yaml --substitutions=_IMAGE=${IMAGE_NAME}

if [[ "${CREATE_VPC_SUBNET}" == "true" ]]; then
  echo "Ensuring VPC subnet ${VPC_SUBNET} exists..."
  gcloud compute networks subnets describe "${VPC_SUBNET}" \
    --region "${REGION}" \
    --project "${PROJECT_ID}" >/dev/null 2>&1 || \
  gcloud compute networks subnets create "${VPC_SUBNET}" \
    --network "${VPC_NETWORK}" \
    --range "10.0.1.0/24" \
    --region "${REGION}" \
    --enable-private-ip-google-access \
    --project "${PROJECT_ID}"
fi

if [[ "${CREATE_CLOUD_NAT}" == "true" ]]; then
  echo "Ensuring Cloud Router ${CLOUD_ROUTER_NAME} exists..."
  gcloud compute routers describe "${CLOUD_ROUTER_NAME}" \
    --region "${REGION}" \
    --project "${PROJECT_ID}" >/dev/null 2>&1 || \
  gcloud compute routers create "${CLOUD_ROUTER_NAME}" \
    --network "${VPC_NETWORK}" \
    --region "${REGION}" \
    --project "${PROJECT_ID}"

  echo "Ensuring Cloud NAT ${CLOUD_NAT_NAME} exists..."
  gcloud compute routers nats describe "${CLOUD_NAT_NAME}" \
    --router "${CLOUD_ROUTER_NAME}" \
    --region "${REGION}" \
    --project "${PROJECT_ID}" >/dev/null 2>&1 || \
  gcloud compute routers nats create "${CLOUD_NAT_NAME}" \
    --router "${CLOUD_ROUTER_NAME}" \
    --region "${REGION}" \
    --auto-allocate-nat-external-ips \
    --nat-all-subnet-ip-ranges \
    --project "${PROJECT_ID}"
fi

gcloud run deploy "$SERVICE_NAME" \
  --image "${IMAGE_NAME}:latest" \
  --region "$REGION" \
  --allow-unauthenticated \
  --service-account "${SERVICE_ACCOUNT}" \
  --labels "${HACKATHON_LABEL}" \
  --clear-secrets \
  --set-env-vars DAILY_API_KEY_SECRET_NAME=DAILY_API_KEY,ADMIN_API_KEY_SECRET_NAME=${ADMIN_API_KEY_SECRET_NAME},PROJECT_ID=${PROJECT_ID},DATASET_ID=${DATASET_ID},LLM_DATASET_ID=${LLM_DATASET_ID},GCS_BUCKET_NAME=${GCS_BUCKET_NAME},DAILY_BUDGET_USD=${DAILY_BUDGET_USD},MAX_REQUESTS_PER_IP=${MAX_REQUESTS_PER_IP},RATE_LIMIT_NS=${RATE_LIMIT_NS},VACATION_MODE=${VACATION_MODE},VACATION_END_DATE=${VACATION_END_DATE},CONTENT_API_BASE=${CONTENT_API_BASE},BOT_START_URL=${BOT_START_URL},BOT_START_ORIGIN=${BOT_START_ORIGIN} \
  --network "${VPC_NETWORK}" \
  --subnet "${VPC_SUBNET}" \
  --vpc-egress "${VPC_EGRESS}" \
  --timeout "${REQUEST_TIMEOUT}" \
  $( [[ "${CPU_ALWAYS_ALLOCATED}" == "true" ]] && echo "--no-cpu-throttling" )

SERVICE_URL=$(gcloud run services describe "${SERVICE_NAME}" --region "${REGION}" --format 'value(status.url)')

echo ""
echo "=== Deployment Complete ==="
echo "Service URL: ${SERVICE_URL}"
echo "Label:       ${HACKATHON_LABEL}"
