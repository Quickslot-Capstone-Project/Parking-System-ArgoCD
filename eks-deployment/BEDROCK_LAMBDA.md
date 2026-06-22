# DynamoDB-grounded Nova assistant

## Architecture

```text
Browser
  -> ALB
  -> booking-service
  -> AI assistant Lambda
      -> DynamoDB bookings and slots (read-only)
      -> Amazon Bedrock Nova Pro
  -> grounded assistant response
```

The Lambda reads a bounded live context from the slots and bookings tables, appends it to the application prompt, and instructs Nova not to invent parking or booking facts. The booking service invokes Lambda synchronously. If Lambda fails, the service automatically uses its existing direct Bedrock path, which preserves application availability.

## Safe staged rollout

### 1. Create Lambda without changing the running application

From local PowerShell:

```powershell
cd C:\Users\Admin\Documents\AWS_Project\Parking-System\terraform
terraform plan
terraform apply
```

Expected plan:

```text
Plan: 5 to add, 1 to change, 0 to destroy
```

The single update only adds `lambda:InvokeFunction` to the existing application role. It does not replace EKS, the VPC, DynamoDB, ALB, or any workload.

Verify the function:

```powershell
terraform output -raw ai_assistant_lambda_name
aws lambda get-function `
  --region us-east-1 `
  --function-name smart-parking-dev-ai-assistant
```

### 2. Build a booking image containing the optional Lambda client

The currently deployed `nimeshsv814/tf-booking-service:v7.0.1` predates the Lambda invocation code. It continues using direct Bedrock and is intentionally unchanged.

Build and push a new immutable tag from the repository root:

```powershell
docker login
docker build -t nimeshsv814/tf-booking-service:v7.0.2 .\booking-service
docker push nimeshsv814/tf-booking-service:v7.0.2
```

After the push succeeds, change the booking image tag from `v7.0.1` to `v7.0.2` in:

- `eks-deployment/helm/values.yaml`
- `eks-deployment/helm/values/booking-service.yaml`

Do not change the Helm tag before the image exists in Docker Hub.

### 3. Roll out only booking-service through Helm

Make the updated files available in CloudShell, then run:

```bash
cd ~/Parking-System
git pull

helm upgrade --install smart-parking ./eks-deployment/helm \
  --namespace sps-ns \
  --wait \
  --timeout 15m

kubectl rollout status deployment/booking-deploy \
  --namespace sps-ns \
  --timeout=5m
```

Verify the configuration:

```bash
kubectl exec --namespace sps-ns deployment/booking-deploy -- \
  printenv AI_ASSISTANT_LAMBDA_NAME BEDROCK_MODEL_ID BEDROCK_REGION
```

Expected output:

```text
smart-parking-dev-ai-assistant
amazon.nova-pro-v1:0
us-east-1
```

## Verification

Invoke the assistant through the application and confirm its provider:

```bash
curl -s -X POST "http://$ALB_HOSTNAME/api/booking/assistant/chat" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"message":"Which available four-wheeler slot has low demand for the next 2 hours?"}'
```

Then inspect both components:

```bash
kubectl logs --namespace sps-ns deployment/booking-deploy --tail=200 | grep -i -E 'lambda|bedrock'

aws logs tail /aws/lambda/smart-parking-dev-ai-assistant \
  --region us-east-1 \
  --since 10m
```

If Lambda invocation fails, the booking service logs the failure and uses direct Bedrock automatically rather than failing the user request.
