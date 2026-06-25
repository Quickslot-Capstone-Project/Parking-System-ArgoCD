{{- define "smart-parking.namespace" -}}
{{- default .Release.Namespace .Values.namespace -}}
{{- end -}}

{{- define "smart-parking.environment" -}}
{{- $namespace := include "smart-parking.namespace" . -}}
{{- default $namespace .Values.environment -}}
{{- end -}}

{{- define "smart-parking.image" -}}
{{- if .tag -}}
{{ printf "%s:%s" .repository .tag }}
{{- else -}}
{{ .repository }}
{{- end -}}
{{- end -}}

{{- define "smart-parking.rolloutSteps" -}}
{{- $strategies := default dict .Values.rolloutStrategy -}}
{{- $environment := include "smart-parking.environment" . -}}
{{- $strategy := (get $strategies $environment) | default (get $strategies "default") | default dict -}}
{{- if $strategy.steps -}}
{{ toYaml $strategy.steps }}
{{- end -}}
{{- end -}}

{{- define "smart-parking.renderConfigMap" -}}
{{- $root := .root -}}
{{- $configMap := .configMap -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ $configMap.name }}
  namespace: {{ include "smart-parking.namespace" $root }}
data:
{{ toYaml $configMap.data | nindent 2 }}
{{- end -}}

{{- define "smart-parking.renderDeployment" -}}
{{- $root := .root -}}
{{- $deployment := .deployment -}}
{{- $service := default dict .service -}}
{{- $deploymentStrategy := default dict $deployment.strategy -}}
{{- $rollingUpdate := default dict $deploymentStrategy.rollingUpdate -}}
{{- $rolloutEnabled := and $root.Values.rollout $root.Values.rollout.enabled -}}
{{- $rolloutSteps := include "smart-parking.rolloutSteps" $root -}}
{{- if $rolloutEnabled }}
apiVersion: argoproj.io/v1alpha1
kind: Rollout
{{- else }}
apiVersion: apps/v1
kind: Deployment
{{- end }}
metadata:
  name: {{ $deployment.name }}
  namespace: {{ include "smart-parking.namespace" $root }}
spec:
  replicas: {{ $deployment.replicas }}
  selector:
    matchLabels:
{{ toYaml $deployment.selectorLabels | nindent 6 }}
{{- if $rolloutEnabled }}
  strategy:
    blueGreen:
      activeService: {{ $service.name }}
      previewService: {{ printf "%s-preview" $service.name }}
      autoPromotionEnabled: false
{{- else if $deployment.strategy }}
  strategy:
{{ toYaml $deployment.strategy | nindent 4 }}
{{- end }}
  template:
    metadata:
      labels:
{{ toYaml $deployment.podLabels | nindent 8 }}
{{- with $deployment.podAnnotations }}
      annotations:
{{ toYaml . | nindent 8 }}
{{- end }}
    spec:
{{- if $deployment.serviceAccountName }}
      serviceAccountName: {{ $deployment.serviceAccountName }}
{{- else if and $root.Values.serviceAccount $root.Values.serviceAccount.enabled }}
      serviceAccountName: {{ $root.Values.serviceAccount.name }}
{{- end }}
      containers:
{{- range $container := $deployment.containers }}
        - name: {{ $container.name }}
          image: {{ include "smart-parking.image" (default $container.image $deployment.image) }}
{{- if $container.ports }}
          ports:
{{- range $port := $container.ports }}
            - containerPort: {{ $port.containerPort }}
{{- end }}
{{- end }}
{{- if $container.envFromConfigMaps }}
          envFrom:
{{- range $configMapName := $container.envFromConfigMaps }}
            - configMapRef:
                name: {{ $configMapName }}
{{- end }}
{{- end }}
{{- if $container.resources }}
          resources:
{{ toYaml $container.resources | nindent 12 }}
{{- end }}
{{- if $container.livenessProbe }}
          livenessProbe:
{{ toYaml $container.livenessProbe | nindent 12 }}
{{- end }}
{{- if $container.readinessProbe }}
          readinessProbe:
{{ toYaml $container.readinessProbe | nindent 12 }}
{{- end }}
{{- if $container.startupProbe }}
          startupProbe:
{{ toYaml $container.startupProbe | nindent 12 }}
{{- end }}
{{- if $container.volumeMounts }}
          volumeMounts:
{{ toYaml $container.volumeMounts | nindent 12 }}
{{- end }}
{{- end }}
{{- if $deployment.volumes }}
      volumes:
{{ toYaml $deployment.volumes | nindent 8 }}
{{- end }}
{{- end -}}

{{- define "smart-parking.renderService" -}}
{{- $root := .root -}}
{{- $service := .service -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ $service.name }}
  namespace: {{ include "smart-parking.namespace" $root }}
{{- with $service.annotations }}
  annotations:
{{ toYaml . | nindent 4 }}
{{- end }}
spec:
  selector:
{{ toYaml $service.selectorLabels | nindent 4 }}
  ports:
{{- range $port := $service.ports }}
    - port: {{ $port.port }}
      targetPort: {{ $port.targetPort }}
{{- if $port.protocol }}
      protocol: {{ $port.protocol }}
{{- end }}
{{- end }}
  type: {{ $service.type }}
{{- if hasKey $service "clusterIP" }}
  clusterIP: {{ $service.clusterIP }}
{{- end }}
{{- end -}}

{{- define "smart-parking.renderPreviewService" -}}
{{- $root := .root -}}
{{- $service := .service -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ printf "%s-preview" $service.name }}
  namespace: {{ include "smart-parking.namespace" $root }}
spec:
  selector:
{{ toYaml $service.selectorLabels | nindent 4 }}
  ports:
{{- range $port := $service.ports }}
    - port: {{ $port.port }}
      targetPort: {{ $port.targetPort }}
{{- if $port.protocol }}
      protocol: {{ $port.protocol }}
{{- end }}
{{- end }}
  type: {{ $service.type }}
{{- if hasKey $service "clusterIP" }}
  clusterIP: {{ $service.clusterIP }}
{{- end }}
{{- end -}}

{{- define "smart-parking.renderServiceWithPreview" -}}
{{ include "smart-parking.renderService" . }}
{{- $root := .root -}}
{{- if and $root.Values.rollout $root.Values.rollout.enabled }}
---
{{ include "smart-parking.renderPreviewService" . }}
{{- end }}
{{- end -}}

{{- define "smart-parking.renderStorageClass" -}}
{{- $storageClass := .storageClass -}}
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: {{ $storageClass.name }}
provisioner: {{ $storageClass.provisioner }}
parameters:
{{ toYaml $storageClass.parameters | nindent 2 }}
{{- end -}}

{{- define "smart-parking.renderStatefulSet" -}}
{{- $root := .root -}}
{{- $statefulSet := .statefulSet -}}
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {{ $statefulSet.name }}
  namespace: {{ include "smart-parking.namespace" $root }}
spec:
  replicas: {{ $statefulSet.replicas }}
  minReadySeconds: {{ $statefulSet.minReadySeconds }}
  selector:
    matchLabels:
{{ toYaml $statefulSet.selectorLabels | nindent 6 }}
  template:
    metadata:
      labels:
{{ toYaml $statefulSet.podLabels | nindent 8 }}
    spec:
      terminationGracePeriodSeconds: {{ $statefulSet.terminationGracePeriodSeconds }}
      containers:
{{- range $container := $statefulSet.containers }}
        - name: {{ $container.name }}
          image: {{ include "smart-parking.image" $container.image }}
{{- if $container.ports }}
          ports:
{{- range $port := $container.ports }}
            - containerPort: {{ $port.containerPort }}
{{- end }}
{{- end }}
{{- if $container.resources }}
          resources:
{{ toYaml $container.resources | nindent 12 }}
{{- end }}
{{- if $container.volumeMounts }}
          volumeMounts:
{{ toYaml $container.volumeMounts | nindent 12 }}
{{- end }}
{{- end }}
{{- if $statefulSet.volumeClaimTemplates }}
  volumeClaimTemplates:
{{ toYaml $statefulSet.volumeClaimTemplates | nindent 4 }}
{{- end }}
{{- end -}}
