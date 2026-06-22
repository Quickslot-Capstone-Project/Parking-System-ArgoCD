# Deploy from AWS CloudShell

EKS does not provide SSH or shell access to its control-plane/master nodes. The control plane is managed by AWS. Use AWS CloudShell as the AWS-hosted Linux shell for `kubectl` and Helm.

## 1. Apply the controller IAM resources locally

The AWS Load Balancer Controller IAM policy, role, and Pod Identity association are Terraform resources and must exist before installing the controller.

Run this once from local PowerShell:

```powershell
cd C:\Users\Admin\Documents\AWS_Project\Parking-System\terraform
terraform plan
terraform apply
```

The plan should add the load-balancer-controller IAM policy, role, attachment, and Pod Identity association without recreating EKS.

## 2. Make the deployment chart available to CloudShell

CloudShell cannot see files stored on your Windows computer. Choose one method:

- Commit and push the `terraform` and `eks-deployment` changes, then clone the repository in CloudShell.
- Use **CloudShell Actions > Upload file** to upload an archive containing `eks-deployment`.

For the Git workflow, run in CloudShell after the changes are pushed:

```bash
git clone https://github.com/UST-Capstone-Project/Parking-System.git
cd Parking-System
```

## 3. Configure the EKS connection in CloudShell

Run these commands in AWS CloudShell:

```bash
export AWS_REGION=us-east-1
export CLUSTER_NAME=smart-parking-dev-eks

aws eks update-kubeconfig \
  --region "$AWS_REGION" \
  --name "$CLUSTER_NAME"

kubectl config current-context
kubectl get nodes

export VPC_ID=$(aws eks describe-cluster \
  --region "$AWS_REGION" \
  --name "$CLUSTER_NAME" \
  --query 'cluster.resourcesVpcConfig.vpcId' \
  --output text)

echo "Cluster: $CLUSTER_NAME"
echo "VPC: $VPC_ID"
```

Do not continue until the nodes show `Ready` and both variables print non-empty values.

## 4. Install Helm in CloudShell

Check whether Helm is already available:

```bash
helm version
```

If it is not installed:

```bash
curl -fsSL -o get_helm.sh \
  https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
helm version
```

## 5. Install the AWS Load Balancer Controller

```bash
helm repo add eks https://aws.github.io/eks-charts --force-update
helm repo update

helm upgrade --install aws-load-balancer-controller \
  eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set region="$AWS_REGION" \
  --set vpcId="$VPC_ID" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --wait \
  --timeout 10m
```

Verify the controller:

```bash
kubectl rollout status \
  deployment/aws-load-balancer-controller \
  --namespace kube-system \
  --timeout=5m

kubectl get pods \
  --namespace kube-system \
  --selector app.kubernetes.io/name=aws-load-balancer-controller
```

## 6. Deploy the application

Run this from the repository root in CloudShell, where `eks-deployment/helm` exists:

```bash
helm lint ./eks-deployment/helm

helm upgrade --install smart-parking ./eks-deployment/helm \
  --namespace sps-ns \
  --create-namespace \
  --wait \
  --timeout 15m
```

## 7. Obtain and test the ALB URL

```bash
kubectl get pods,service,ingress --namespace sps-ns

export ALB_HOSTNAME=$(kubectl get ingress smart-parking-alb \
  --namespace sps-ns \
  --output jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "Application URL: http://$ALB_HOSTNAME"
```

ALB provisioning can take several minutes. If the hostname is empty, wait and run the export command again.

```bash
curl -I "http://$ALB_HOSTNAME/"
curl -i "http://$ALB_HOSTNAME/auth/health"
curl -i "http://$ALB_HOSTNAME/parking/health"
curl -i "http://$ALB_HOSTNAME/booking/health"
curl -i "http://$ALB_HOSTNAME/payment/health"
curl -i "http://$ALB_HOSTNAME/notification/health"
```

## Troubleshooting

```bash
kubectl describe ingress smart-parking-alb --namespace sps-ns
kubectl get events --namespace sps-ns --sort-by=.lastTimestamp
kubectl logs --namespace kube-system deployment/aws-load-balancer-controller
```

### Login/register returns 405 from Nginx

The published frontend image was built without Vite API base-path values, so it sends root-level requests such as `/login` rather than `/auth/login`. This chart mounts `frontend-nginx-config` into the frontend pods and proxies those root-level API paths to their internal Kubernetes services.

After pulling this chart update, apply it and wait for the frontend rollout:

```bash
helm upgrade --install smart-parking ./eks-deployment/helm \
  --namespace sps-ns \
  --wait \
  --timeout 15m

kubectl rollout status deployment/frontend-deploy \
  --namespace sps-ns \
  --timeout=5m

kubectl exec --namespace sps-ns deployment/frontend-deploy -- \
  nginx -t
```

Confirm that an unprefixed login request now reaches Express instead of returning an Nginx `405`:

```bash
curl -i -X POST "http://$ALB_HOSTNAME/login" \
  -H 'Content-Type: application/json' \
  -d '{"email":"user@parking.com","password":"User@123"}'
```

If the controller reports `AccessDenied`, confirm that the local `terraform apply` completed and check the association:

```bash
aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" \
  --region "$AWS_REGION"
```

## Safe removal

```bash
helm uninstall smart-parking --namespace sps-ns --wait
kubectl get ingress --all-namespaces
helm uninstall aws-load-balancer-controller --namespace kube-system --wait
```

Only run `terraform destroy` locally after the Ingress and AWS ALB have been deleted.

## Enable the Amazon Nova AI assistant

The booking image already contains the Bedrock Runtime SDK and Converse integration. Terraform adds Nova Pro invocation permission to the existing `smart-parking-app` Pod Identity role, which already provides the application with DynamoDB access. No service account or cluster resource is replaced.

First apply the three additive IAM resources from local PowerShell:

```powershell
cd C:\Users\Admin\Documents\AWS_Project\Parking-System\terraform
terraform plan
terraform apply
```

With the optional grounded-assistant Lambda included, the plan adds the Lambda resources and extends the existing application IAM policy. It must show `0 to destroy`; review the exact counts before approving.

After the updated chart is available in CloudShell, roll out booking-service:

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

Verify its identity and configuration:

```bash
kubectl get serviceaccount smart-parking-app --namespace sps-ns

kubectl get deployment booking-deploy --namespace sps-ns \
  --output jsonpath='{.spec.template.spec.serviceAccountName}{"\n"}'

kubectl exec --namespace sps-ns deployment/booking-deploy -- \
  printenv BEDROCK_MODEL_ID BEDROCK_REGION
```

The deployment service account should be `smart-parking-app`. Expected environment values:

```text
amazon.nova-pro-v1:0
us-east-1
```

Test the assistant using an authenticated token:

```bash
export TOKEN=$(curl -s -X POST "http://$ALB_HOSTNAME/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d '{"email":"user@parking.com","password":"User@123"}' | \
  python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')

curl -s -X POST "http://$ALB_HOSTNAME/api/booking/assistant/chat" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"message":"Recommend a low demand four-wheeler parking slot for 2 hours"}'
```

The response should contain `"aiProvider":"BEDROCK_NOVA"`. If it contains `LOCAL_FALLBACK`, inspect:

```bash
kubectl logs --namespace sps-ns deployment/booking-deploy --tail=200 | \
  grep -i bedrock
```
