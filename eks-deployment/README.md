DEV
# Deploy Smart Parking to EKS through an AWS ALB

> EKS has no accessible master-node shell. To run Helm from an AWS-hosted Linux shell instead of local PowerShell, follow [CLOUDSHELL_DEPLOY.md](./CLOUDSHELL_DEPLOY.md).

> For the optional DynamoDB-grounded Nova Lambda architecture and its non-disruptive rollout, follow [BEDROCK_LAMBDA.md](./BEDROCK_LAMBDA.md).

This folder is an independent copy of `infra/helm`. The original `infra` directory is unchanged.

The chart deploys the application with DynamoDB, EKS Pod Identity, and an internet-facing Application Load Balancer. The ALB routes `/auth`, `/parking`, `/booking`, `/payment`, and `/notification` to their services and sends `/` to the frontend.

## 1. Apply the ALB controller IAM resources

The EKS cluster may already exist, but Terraform now also manages the AWS Load Balancer Controller policy, IAM role, and Pod Identity association:

```powershell
Set-Location terraform
terraform apply
```

Review the plan and enter `yes`. This updates the existing infrastructure; it does not recreate the cluster.

## 2. Configure kubectl

```powershell
$ClusterName = terraform output -raw eks_cluster_name
$VpcId = terraform output -raw vpc_id
aws eks update-kubeconfig --region us-east-1 --name $ClusterName
kubectl get nodes
Set-Location ..
```

Both worker nodes must be `Ready`.

## 3. Install the AWS Load Balancer Controller

The Terraform Pod Identity association expects the service account name `aws-load-balancer-controller` in `kube-system`. Let the controller chart create that service account; no IAM annotation or access key is needed.

```powershell
helm repo add eks https://aws.github.io/eks-charts --force-update
helm repo update

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller `
  --namespace kube-system `
  --set clusterName=$ClusterName `
  --set region=us-east-1 `
  --set vpcId=$VpcId `
  --set serviceAccount.create=true `
  --set serviceAccount.name=aws-load-balancer-controller `
  --wait `
  --timeout 10m
```

Verify it before installing the application:

```powershell
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=5m
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
aws eks list-pod-identity-associations --cluster-name $ClusterName --region us-east-1
```

## 4. Validate and install the application

From the repository root:

```powershell
helm lint ./eks-deployment/helm
helm template smart-parking ./eks-deployment/helm --namespace sps-ns > $null

helm upgrade --install smart-parking ./eks-deployment/helm `
  --namespace sps-ns `
  --create-namespace `
  --wait `
  --timeout 15m
```

The chart uses these images:

| Component | Image |
| --- | --- |
| Frontend | `nimeshsv814/tf-frontend:v6.0.8` |
| Auth | `nimeshsv814/tf-auth-service:v4.0.0` |
| Parking | `nimeshsv814/tf-parking-service:v5.0.0` |
| Booking | `nimeshsv814/tf-booking-service:v7.0.1` |
| Payment | `nimeshsv814/tf-payment-service:v7.0.0` |
| Notification | `nimeshsv814/tf-notification-service:v4.0.0` |
| Scheduler | `nimeshsv814/tf-scheduler-service:latest` |

## 5. Wait for the ALB and obtain its URL

```powershell
kubectl get pods,service,ingress -n sps-ns
kubectl describe ingress smart-parking-alb -n sps-ns

$AlbHostname = kubectl get ingress smart-parking-alb -n sps-ns `
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

Write-Host "Application URL: http://$AlbHostname"
```

ALB creation usually takes several minutes. If `$AlbHostname` is empty, wait and run the command again.

Test the frontend and API health endpoints:

```powershell
Invoke-WebRequest "http://$AlbHostname/" -UseBasicParsing
Invoke-WebRequest "http://$AlbHostname/auth/health" -UseBasicParsing
Invoke-WebRequest "http://$AlbHostname/parking/health" -UseBasicParsing
Invoke-WebRequest "http://$AlbHostname/booking/health" -UseBasicParsing
Invoke-WebRequest "http://$AlbHostname/payment/health" -UseBasicParsing
Invoke-WebRequest "http://$AlbHostname/notification/health" -UseBasicParsing
```

## Troubleshooting

```powershell
kubectl get events -n sps-ns --sort-by=.lastTimestamp
kubectl logs -n kube-system deployment/aws-load-balancer-controller
kubectl describe ingress smart-parking-alb -n sps-ns
kubectl describe pod -n sps-ns <pod-name>
kubectl logs -n sps-ns <pod-name>
```

Common checks:

- `IngressClass alb` errors mean the AWS Load Balancer Controller is not running.
- `AccessDenied` in controller logs means the Terraform IAM/Pod Identity update was not applied.
- `ImagePullBackOff` means the image/tag is unavailable or private.
- Unhealthy ALB targets usually indicate a `/health` endpoint or pod startup problem.

## Safe removal and infrastructure destruction

Keep the controller running while deleting the application. It needs to remove the ALB, target groups, security groups, and finalizers.

```powershell
# Delete the application and Ingress first.
helm uninstall smart-parking --namespace sps-ns --wait

# Confirm the Ingress is gone before removing its controller.
kubectl get ingress --all-namespaces

# Remove the controller only after it has cleaned up the ALB.
helm uninstall aws-load-balancer-controller --namespace kube-system --wait

# Destroy AWS infrastructure last.
Set-Location terraform
terraform destroy
```

If an Ingress or AWS load balancer still exists, wait before running `terraform destroy`. This prevents ALB network interfaces and security groups from blocking subnet/VPC deletion.
