# SQS rollout

SQS is disabled by default. The current HTTP notification and inline invoice
paths remain active until `SQS_ENABLED` is explicitly changed to `"true"`.

## 1. Create the queues

From `Parking-System/terraform`:

```powershell
terraform init -backend-config="backend.hcl"
terraform plan
terraform apply
terraform output sqs_queue_urls
```

Terraform creates separate notification and invoice queues for dev and prod,
their dead-letter queues, KMS keys, redrive policies, alarms, and Pod Identity
permissions. The bootstrap backend is not applied again.

## 2. Build and push SQS-capable images

Choose unused image tags and run from `Parking-System`:

```powershell
docker build -t nimeshsv814/tf-booking-service:<new-tag> ./booking-service
docker build -t nimeshsv814/tf-payment-service:<new-tag> ./payment-service
docker build -t nimeshsv814/tf-notification-service:<new-tag> ./notification-service

docker push nimeshsv814/tf-booking-service:<new-tag>
docker push nimeshsv814/tf-payment-service:<new-tag>
docker push nimeshsv814/tf-notification-service:<new-tag>
```

Update only the corresponding image tags in `helm/values/argocd-dev.yaml`,
commit, push, and let Argo CD sync. Keep `SQS_ENABLED: "false"` for this first
deployment and verify all three services are healthy.

## 3. Enable dev first

In `helm/values/argocd-dev.yaml`, change `SQS_ENABLED` to `"true"` under:

- `bookingService.configMap.data`
- `paymentService.configMap.data`
- `notificationService.configMap.data`

Commit and sync dev. Create a booking and payment, then verify:

```bash
kubectl logs -n dev deploy/notification-deploy --tail=100
kubectl logs -n dev deploy/payment-deploy --tail=100
aws sqs get-queue-attributes --queue-url <dev-queue-url> --attribute-names All --region us-east-1
```

If needed, rollback safely by setting all three dev flags back to `"false"`.
The services immediately return to HTTP notifications and inline invoices.

## 4. Enable prod

After dev validation, deploy the same image tags to
`helm/values/argocd-prod.yaml`, verify with SQS disabled, and then change the
three prod flags to `"true"`.

