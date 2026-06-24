# Smart Parking Argo CD app-of-apps

This directory is the EKS-compatible copy of the existing `infra/argocd` pattern. The original `infra` directory is unchanged.

## GitOps hierarchy

```text
smart-parking-app-of-apps (tracks master)
├── smart-parking-dev  -> dev branch    -> dev namespace
└── smart-parking-prod -> master branch -> prod namespace
```

Both child Applications render `eks-deployment/helm`. Dev uses `values/argocd-dev.yaml`; prod uses `values/argocd-prod.yaml`.

Payment invoice storage rollout and validation are documented in [`../INVOICE_STORAGE.md`](../INVOICE_STORAGE.md).

Each environment file owns its replica counts, Ingress name, and all seven image repositories/tags. The shared `values.yaml` remains the chart default, but Argo CD image promotion should update only the environment override file.

## Important data-plane note

Both environments currently use the same DynamoDB tables and AI Lambda created by the single Terraform stack. Kubernetes workloads and ALBs are separated by namespace, but application data is shared. Fully isolated data requires separate Terraform environment stacks/state, which is intentionally outside this migration.

## 1. Apply namespace Pod Identity associations

The dev and prod pods need the same existing application IAM role that currently works in `sps-ns`. From the local Terraform directory:

```powershell
terraform plan
terraform apply
```

The plan adds two EKS Pod Identity associations, one for `dev/smart-parking-app` and one for `prod/smart-parking-app`. It does not replace the running `sps-ns` association.

## 2. Commit and promote the GitOps configuration

The verified repository is:

```text
https://github.com/UST-Capstone-Project/Parking-System.git
```

Push the files to `dev`:

```bash
git checkout dev
git add eks-deployment terraform
git commit -m "add Argo CD app of apps for dev and prod"
git push origin dev
```

Create and merge a pull request from `dev` to `master`. This initial merge is required because the parent and prod Applications track `master`, and `eks-deployment/helm` does not currently exist there.

After the merge, confirm these paths exist on `master`:

```text
eks-deployment/argocd/environments/dev.yaml
eks-deployment/argocd/environments/prod.yaml
eks-deployment/helm/Chart.yaml
```

## 3. Install Argo CD

From AWS CloudShell with kubectl configured for the EKS cluster:

```bash
kubectl create namespace argocd

kubectl apply --namespace argocd \
  --filename https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl rollout status deployment/argocd-server \
  --namespace argocd \
  --timeout=10m

kubectl get pods --namespace argocd
```

If the namespace already exists, the `AlreadyExists` message is harmless; continue with `kubectl apply`.

## 4. Bootstrap the app-of-apps

Pull the merged `master` content in CloudShell, then apply only the project and parent Application:

```bash
git checkout master
git pull origin master

kubectl apply --filename eks-deployment/argocd/project.yaml
kubectl apply --filename eks-deployment/argocd/application.yaml
```

The parent automatically creates and synchronizes both child Applications.

```bash
kubectl get applications --namespace argocd

kubectl get application smart-parking-dev --namespace argocd \
  --output jsonpath='{.status.sync.status}{" / "}{.status.health.status}{"\n"}'

kubectl get application smart-parking-prod --namespace argocd \
  --output jsonpath='{.status.sync.status}{" / "}{.status.health.status}{"\n"}'
```

Expected for both:

```text
Synced / Healthy
```

Check the two environments and ALBs:

```bash
kubectl get pods,service,ingress --namespace dev
kubectl get pods,service,ingress --namespace prod
```

## 5. Stop manual Helm management

Once both Applications are healthy, make deployment changes only through Git. Do not run `helm upgrade` against the Argo-managed dev or prod releases.

Dev workflow:

```bash
git checkout dev
# Edit eks-deployment/helm files
git add eks-deployment/helm
git commit -m "update dev deployment"
git push origin dev
```

Argo CD automatically deploys this to `dev`. Promote the tested commit through a pull request into `master`; Argo CD then deploys it to `prod`.

For example, a future CD pipeline promoting booking-service to dev should update only:

```yaml
# eks-deployment/helm/values/argocd-dev.yaml
bookingService:
  deployment:
    image:
      repository: nimeshsv814/tf-booking-service
      tag: v7.0.2
```

After testing, promote the desired tag in `values/argocd-prod.yaml` through the normal `dev` to `master` pull request. Do not have CI update the shared `values.yaml`, because that file is not environment-specific.

## 6. Access the UI

The app-of-apps includes `smart-parking-argocd-edge`, which exposes Argo CD
through the production ALB and CloudFront path `quickslot.site/argocd`.

After the edge Application syncs, restart the Argo CD server once so it rereads
the `/argocd` command parameters:

```bash
kubectl rollout restart deployment/argocd-server --namespace argocd
kubectl rollout status deployment/argocd-server --namespace argocd --timeout=10m
```

This configures Argo CD for the `/argocd` subpath and creates an
`argocd-server-edge` Ingress in the same AWS Load Balancer Controller group as
the prod application Ingress. The prod app and Argo CD Ingresses must both use:

```text
alb.ingress.kubernetes.io/group.name: smart-parking-prod-edge
```

After the prod Application syncs and the Argo CD edge manifest is applied, the
dashboard should be available at:

```text
https://quickslot.site/argocd
```

Get the initial password:

```bash
kubectl get secret argocd-initial-admin-secret \
  --namespace argocd \
  --output jsonpath='{.data.password}' | base64 --decode
echo
```

From a workstation with kubectl configured:

```powershell
kubectl port-forward service/argocd-server -n argocd 8080:443
```

Open `https://localhost:8080` and sign in as `admin`.

## Migration from the existing sps-ns Helm release

The current `sps-ns` release remains untouched while dev and prod are created. Validate both Argo environments first. When you no longer need the old release, remove it separately:

```bash
helm uninstall smart-parking --namespace sps-ns --wait
```

Do not run that command until the dev/prod Applications and their ALBs are healthy.

## Troubleshooting

```bash
kubectl describe application smart-parking-app-of-apps --namespace argocd
kubectl describe application smart-parking-dev --namespace argocd
kubectl describe application smart-parking-prod --namespace argocd
kubectl logs deployment/argocd-repo-server --namespace argocd --tail=200
kubectl get events --namespace dev --sort-by=.lastTimestamp
kubectl get events --namespace prod --sort-by=.lastTimestamp
```

- `path does not exist`: the required files were not merged to the tracked branch.
- DynamoDB `AccessDenied` or missing credentials: apply the two Terraform Pod Identity associations.
- Dev syncs but prod fails: confirm the chart and prod values exist on `master`.
- `ImagePullBackOff`: confirm the image tag exists in Docker Hub.
