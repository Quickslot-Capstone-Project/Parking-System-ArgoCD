# KMS-encrypted payment invoice storage

The existing payment image generates PDF invoices with PDFKit and uploads them through the AWS SDK. This setup supplies the missing AWS infrastructure, IAM permissions, and environment configuration.

## Architecture

```text
dev payment pod  -> dev S3 invoice bucket  -> dev KMS key
prod payment pod -> prod S3 invoice bucket -> prod KMS key
```

Each bucket is private, versioned, TLS-only, and requires KMS encryption for uploads. KMS automatic key rotation and S3 Bucket Keys are enabled.

## 1. Create the AWS resources first

From the local Terraform directory:

```powershell
terraform plan
terraform apply
```

Expected plan:

```text
Plan: 17 to add, 0 to change, 0 to destroy
```

Verify the outputs:

```powershell
terraform output invoice_bucket_names
terraform output invoice_kms_alias_arns
```

Expected buckets:

```text
smart-parking-dev-invoices-533595510771-us-east-1
smart-parking-prod-invoices-533595510771-us-east-1
```

## 2. Let Argo CD deploy the configuration

After Terraform succeeds, commit and push the dev values and chart template:

```bash
git checkout dev
git add terraform eks-deployment
git commit -m "add KMS encrypted invoice storage"
git push origin dev
```

Argo CD rolls the dev payment pod because its ConfigMap checksum changes. Verify:

```bash
kubectl rollout status deployment/payment-deploy --namespace dev --timeout=5m

kubectl exec --namespace dev deployment/payment-deploy -- \
  printenv PAYMENT_INVOICE_BUCKET PAYMENT_INVOICE_KMS_KEY_ARN
```

After testing dev, merge `dev` into `master`. Argo CD then applies the prod values and rolls only the prod payment deployment.

## 3. Verify an uploaded PDF

Complete a successful payment through the application, then inspect payment-service logs:

```bash
kubectl logs --namespace dev deployment/payment-deploy --since=10m | grep -i invoice
```

Expected log:

```text
Payment invoice uploaded to s3://smart-parking-dev-invoices-533595510771-us-east-1/payment-invoices/...
```

List and inspect the encrypted object:

```bash
aws s3api list-objects-v2 \
  --region us-east-1 \
  --bucket smart-parking-dev-invoices-533595510771-us-east-1 \
  --prefix payment-invoices/ \
  --query 'Contents[].Key'

aws s3api head-object \
  --region us-east-1 \
  --bucket smart-parking-dev-invoices-533595510771-us-east-1 \
  --key '<key-from-the-list-command>' \
  --query '{ContentType:ContentType,Encryption:ServerSideEncryption,KMSKey:SSEKMSKeyId}'
```

Expected encryption is `aws:kms`.

## Operational notes

- Invoice buckets use `force_destroy = false`; Terraform will not silently delete stored invoices.
- Objects are private. A future download feature should issue short-lived presigned URLs after authorization instead of making the bucket public.
- Dev and prod use separate buckets and KMS keys, although the current application DynamoDB data plane remains shared.
- Apply Terraform before pushing the Argo values. Otherwise invoice upload is skipped or logged as failed until the buckets and IAM policy exist.
