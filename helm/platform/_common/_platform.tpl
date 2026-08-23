{{/*
Canonical platform helper templates shared by every platform workload profile.

Source of truth: helm/platform/_common/_platform.tpl
Generated copies: helm/platform/<profile>/templates/_platform.tpl
Regenerate with: bash helm/platform/sync-common.sh
helm/test/platform-common.test.sh fails when a copy drifts from this source.
*/}}

{{- define "platform.name" -}}
{{- $name := required "workload.name is required" .Values.workload.name -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]{0,51}[a-z0-9])?$" $name) -}}
{{- fail (printf "workload.name %q must be a lowercase kebab-case DNS label of at most 53 characters" $name) -}}
{{- end -}}
{{- $name -}}
{{- end -}}

{{/*
Profile identity and bounds come from the chart's own Chart.yaml annotations.
Helm named templates are global across a wrapper and all of its aliased
dependencies, so a per-chart define would collide between profiles; chart
metadata does not. Annotations survive aliasing, unlike .Chart.Name.
*/}}
{{- define "platform.profileName" -}}
{{- $profile := index .Chart.Annotations "platform.yourown.chat/profile" | toString -}}
{{- if not (regexMatch "^platform-(service|worker|job|stateful)$" $profile) -}}
{{- fail (printf "chart %s lacks a valid platform.yourown.chat/profile annotation" .Chart.Name) -}}
{{- end -}}
{{- $profile -}}
{{- end -}}

{{- define "platform.bounds" -}}
{{- required (printf "chart %s lacks the platform.yourown.chat/bounds annotation" .Chart.Name) (index .Chart.Annotations "platform.yourown.chat/bounds") -}}
{{- end -}}

{{- define "platform.partOf" -}}
{{- default (include "platform.name" .) .Values.workload.partOf -}}
{{- end -}}

{{/*
Platform-owned labels applied to every rendered object. The profile name comes
from the chart's own platform.profileName definition, not from the chart
metadata name, because Helm replaces the metadata name with the dependency
alias inside a wrapper.
*/}}
{{- define "platform.labels" -}}
app: {{ include "platform.name" . }}
app.kubernetes.io/name: {{ include "platform.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: {{ include "platform.profileName" . }}
app.kubernetes.io/part-of: {{ include "platform.partOf" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" (include "platform.profileName" .) .Chart.Version | quote }}
platform.yourown.chat/profile: {{ include "platform.profileName" . }}
platform.yourown.chat/chart-version: {{ .Chart.Version | quote }}
{{- end -}}

{{/* Stable selector labels. The legacy `app` label keeps existing cross-namespace policies valid during migration. */}}
{{- define "platform.selectorLabels" -}}
app: {{ include "platform.name" . }}
app.kubernetes.io/name: {{ include "platform.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Release-supplied immutable image. Only an Artifact Registry repository@sha256 reference is accepted. */}}
{{- define "platform.image" -}}
{{- $image := required "image.digest is required and is supplied by the release pipeline" .Values.image.digest -}}
{{- if not (regexMatch "^[a-z0-9-]+-docker\\.pkg\\.dev/[a-z][a-z0-9-]{4,28}[a-z0-9]/[a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9._/-]*@sha256:[0-9a-f]{64}$" $image) -}}
{{- fail (printf "image.digest %q must be an Artifact Registry repository@sha256 digest; mutable tags and foreign registries are rejected" $image) -}}
{{- end -}}
{{- $image -}}
{{- end -}}

{{- define "platform.imageDigest" -}}
{{- regexReplaceAll "^.*@sha256:" (include "platform.image" .) "" -}}
{{- end -}}

{{/* CPU quantity in millicores. */}}
{{- define "platform.cpuMillis" -}}
{{- $v := toString . -}}
{{- if regexMatch "^[0-9]+m$" $v -}}
{{- trimSuffix "m" $v | atoi -}}
{{- else if regexMatch "^[0-9]+(\\.[0-9]+)?$" $v -}}
{{- int64 (mulf (float64 $v) 1000.0) -}}
{{- else -}}
{{- fail (printf "unsupported CPU quantity %q" $v) -}}
{{- end -}}
{{- end -}}

{{/* Memory quantity in bytes. */}}
{{- define "platform.memoryBytes" -}}
{{- $v := toString . -}}
{{- if not (regexMatch "^[0-9]+(Ki|Mi|Gi|k|M|G)?$" $v) -}}
{{- fail (printf "unsupported memory quantity %q" $v) -}}
{{- end -}}
{{- $num := regexReplaceAll "^([0-9]+).*$" $v "${1}" | int64 -}}
{{- $unit := regexReplaceAll "^[0-9]+" $v "" -}}
{{- $mult := dict "" 1 "k" 1000 "M" 1000000 "G" 1000000000 "Ki" 1024 "Mi" 1048576 "Gi" 1073741824 -}}
{{- mul $num (get $mult $unit) -}}
{{- end -}}

{{/* Validate container resources against the profile bounds published by platform.bounds. */}}
{{- define "platform.validateResources" -}}
{{- $b := fromJson (include "platform.bounds" .) -}}
{{- $r := .Values.container.resources -}}
{{- $reqCPU := include "platform.cpuMillis" (required "container.resources.requests.cpu is required" $r.requests.cpu) | int64 -}}
{{- $reqMem := include "platform.memoryBytes" (required "container.resources.requests.memory is required" $r.requests.memory) | int64 -}}
{{- $limMem := include "platform.memoryBytes" (required "container.resources.limits.memory is required" $r.limits.memory) | int64 -}}
{{- if gt $reqCPU (int64 $b.maxRequestCPUMillis) -}}
{{- fail (printf "container.resources.requests.cpu %s exceeds the %s profile bound of %dm" $r.requests.cpu (include "platform.profileName" .) (int64 $b.maxRequestCPUMillis)) -}}
{{- end -}}
{{- if gt $reqMem (int64 $b.maxRequestMemoryBytes) -}}
{{- fail (printf "container.resources.requests.memory %s exceeds the %s profile bound" $r.requests.memory (include "platform.profileName" .)) -}}
{{- end -}}
{{- if gt $limMem (int64 $b.maxLimitMemoryBytes) -}}
{{- fail (printf "container.resources.limits.memory %s exceeds the %s profile bound" $r.limits.memory (include "platform.profileName" .)) -}}
{{- end -}}
{{- if gt $reqMem $limMem -}}
{{- fail "container.resources.requests.memory must not exceed container.resources.limits.memory" -}}
{{- end -}}
{{- if $r.limits.cpu -}}
{{- $limCPU := include "platform.cpuMillis" $r.limits.cpu | int64 -}}
{{- if gt $limCPU (int64 $b.maxLimitCPUMillis) -}}
{{- fail (printf "container.resources.limits.cpu %s exceeds the %s profile bound of %dm" $r.limits.cpu (include "platform.profileName" .) (int64 $b.maxLimitCPUMillis)) -}}
{{- end -}}
{{- if gt $reqCPU $limCPU -}}
{{- fail "container.resources.requests.cpu must not exceed container.resources.limits.cpu" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Non-secret environment only. Secret material is delivered through secrets.files. */}}
{{- define "platform.validateEnv" -}}
{{- range $k, $v := .Values.container.env -}}
{{- if regexMatch "(?i)(PASSWORD|PASSWD|SECRET|TOKEN|PRIVATE_KEY|API_KEY|CREDENTIALS?)$" $k -}}
{{- fail (printf "container.env.%s looks like a plaintext secret; reference it through secrets.files and pass the mounted file path instead" $k) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Secret delivery requires a dedicated Workload Identity and a Secret Manager project. */}}
{{- define "platform.validateSecrets" -}}
{{- if .Values.secrets.files -}}
{{- if not .Values.identity.googleServiceAccount -}}
{{- fail "secrets.files requires identity.googleServiceAccount (dedicated least-privilege Workload Identity)" -}}
{{- end -}}
{{- if not .Values.secrets.project -}}
{{- fail "secrets.files requires secrets.project (release-supplied Secret Manager project)" -}}
{{- end -}}
{{- $seen := dict -}}
{{- range .Values.secrets.files -}}
{{- if hasKey $seen .file -}}
{{- fail (printf "secrets.files declares file %q more than once" .file) -}}
{{- end -}}
{{- $_ := set $seen .file true -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Resolve a declared container port by name; fails on an undeclared reference. */}}
{{- define "platform.portByName" -}}
{{- $found := dict -}}
{{- range .ports -}}
{{- if eq .name $.name -}}
{{- $_ := set $found "port" . -}}
{{- end -}}
{{- end -}}
{{- if not (hasKey $found "port") -}}
{{- fail (printf "%s references port %q which is not declared in container.ports" .context $.name) -}}
{{- end -}}
{{- toJson $found.port -}}
{{- end -}}

{{- define "platform.probe" -}}
{{- $p := .probe -}}
{{- if and $p.httpGet $p.exec -}}
{{- fail (printf "%s must declare exactly one of httpGet or exec" .context) -}}
{{- end -}}
{{- if $p.httpGet }}
httpGet:
  path: {{ $p.httpGet.path }}
  port: {{ .port }}
{{- else if $p.exec }}
exec:
  command: {{ toJson $p.exec.command }}
{{- else -}}
{{- fail (printf "%s must declare httpGet.path or exec.command" .context) -}}
{{- end }}
{{- if $p.initialDelaySeconds }}
initialDelaySeconds: {{ $p.initialDelaySeconds }}
{{- end }}
periodSeconds: {{ $p.periodSeconds }}
timeoutSeconds: {{ $p.timeoutSeconds }}
failureThreshold: {{ $p.failureThreshold }}
successThreshold: 1
{{- end -}}

{{/* Startup, readiness and liveness probes from container.health. */}}
{{- define "platform.probes" -}}
{{- $h := .Values.container.health -}}
{{- if $h }}
{{- $port := $h.port | default "http" -}}
{{- if or (and $h.readiness $h.readiness.httpGet) (and $h.liveness $h.liveness.httpGet) (and $h.startup $h.startup.httpGet) -}}
{{- $_ := include "platform.portByName" (dict "ports" .Values.container.ports "name" $port "context" "container.health.port") -}}
{{- end -}}
{{- if and $h.startup (or $h.startup.httpGet $h.startup.exec) }}
startupProbe:
  {{- include "platform.probe" (dict "probe" $h.startup "port" $port "context" "container.health.startup") | trim | nindent 2 }}
{{- end }}
{{- if and $h.readiness (or $h.readiness.httpGet $h.readiness.exec) }}
readinessProbe:
  {{- include "platform.probe" (dict "probe" $h.readiness "port" $port "context" "container.health.readiness") | trim | nindent 2 }}
{{- end }}
{{- if and $h.liveness (or $h.liveness.httpGet $h.liveness.exec) }}
livenessProbe:
  {{- include "platform.probe" (dict "probe" $h.liveness "port" $port "context" "container.health.liveness") | trim | nindent 2 }}
{{- end }}
{{- end }}
{{- end -}}

{{/* Platform-owned pod annotations. */}}
{{- define "platform.podAnnotations" -}}
platform.yourown.chat/image-digest: {{ include "platform.imageDigest" . | quote }}
{{- if .Values.secrets.files }}
checksum/secrets: {{ toJson .Values.secrets | sha256sum | quote }}
{{- end }}
{{- if and .Values.observability .Values.observability.metrics .Values.observability.metrics.enabled }}
{{- $m := .Values.observability.metrics }}
{{- $port := fromJson (include "platform.portByName" (dict "ports" .Values.container.ports "name" $m.port "context" "observability.metrics.port")) }}
prometheus.io/scrape: "true"
prometheus.io/port: {{ $port.port | quote }}
prometheus.io/path: {{ $m.path | quote }}
{{- end }}
{{- if and .Values.agentRegistry .Values.agentRegistry.enabled }}
iam.gke.io/spiffe-identity-type: agent-identity
{{- end }}
{{- end -}}

{{/* Pod spec body shared by Deployment, StatefulSet, Job and CronJob templates. */}}
{{- define "platform.podSpec" -}}
{{- include "platform.validateResources" . -}}
{{- include "platform.validateEnv" . -}}
{{- include "platform.validateSecrets" . -}}
{{- $c := .Values.container -}}
automountServiceAccountToken: false
enableServiceLinks: false
serviceAccountName: {{ include "platform.name" . }}
priorityClassName: {{ .Values.runtime.priorityClass }}
terminationGracePeriodSeconds: {{ $c.terminationGracePeriodSeconds }}
{{- with .Values.runtime.nodePool }}
nodeSelector:
  pool: {{ . | quote }}
{{- end }}
securityContext:
  runAsNonRoot: true
  runAsUser: {{ $c.runAsUser }}
  runAsGroup: {{ $c.runAsUser }}
  fsGroup: {{ $c.runAsUser }}
  fsGroupChangePolicy: OnRootMismatch
  seccompProfile:
    type: RuntimeDefault
containers:
  - name: {{ include "platform.name" . }}
    image: {{ include "platform.image" . | quote }}
    imagePullPolicy: IfNotPresent
    {{- with $c.command }}
    command: {{ toJson . }}
    {{- end }}
    {{- with $c.args }}
    args: {{ toJson . }}
    {{- end }}
    {{- if $c.env }}
    env:
      {{- range $k, $v := $c.env }}
      - name: {{ $k }}
        value: {{ $v | quote }}
      {{- end }}
    {{- end }}
    {{- if $c.ports }}
    ports:
      {{- range $c.ports }}
      - name: {{ .name }}
        containerPort: {{ .port }}
        protocol: {{ .protocol | default "TCP" }}
      {{- end }}
    {{- end }}
    {{- with (include "platform.probes" . | trim) }}
    {{- . | nindent 4 }}
    {{- end }}
    securityContext:
      allowPrivilegeEscalation: false
      privileged: false
      readOnlyRootFilesystem: true
      runAsNonRoot: true
      capabilities:
        drop: ["ALL"]
    resources:
      requests:
        cpu: {{ $c.resources.requests.cpu | quote }}
        memory: {{ $c.resources.requests.memory | quote }}
      limits:
        {{- with $c.resources.limits.cpu }}
        cpu: {{ . | quote }}
        {{- end }}
        memory: {{ $c.resources.limits.memory | quote }}
    volumeMounts:
      - name: tmp
        mountPath: /tmp
      {{- range $c.writableVolumes }}
      - name: {{ .name }}
        mountPath: {{ .mountPath }}
      {{- end }}
      {{- if .Values.secrets.files }}
      - name: platform-secrets
        mountPath: {{ .Values.secrets.mountPath }}
        readOnly: true
      {{- end }}
      {{- if and (hasKey .Values "persistence") .Values.persistence.enabled }}
      - name: data
        mountPath: {{ .Values.persistence.mountPath }}
      {{- end }}
volumes:
  - name: tmp
    emptyDir:
      sizeLimit: {{ $c.tmpSizeLimit }}
  {{- range $c.writableVolumes }}
  - name: {{ .name }}
    emptyDir:
      sizeLimit: {{ .sizeLimit }}
  {{- end }}
  {{- if .Values.secrets.files }}
  - name: platform-secrets
    csi:
      driver: secrets-store-gke.csi.k8s.io
      readOnly: true
      volumeAttributes:
        secretProviderClass: {{ include "platform.name" . }}-secrets
  {{- end }}
{{- end -}}

{{/* Network peer selector for a typed ingress/egress rule. */}}
{{- define "platform.networkPeer" -}}
{{- $p := .peer -}}
{{- $kinds := 0 -}}
{{- if $p.sameNamespace }}{{ $kinds = add1 $kinds }}{{ end -}}
{{- if $p.namespace }}{{ $kinds = add1 $kinds }}{{ end -}}
{{- if $p.cidr }}{{ $kinds = add1 $kinds }}{{ end -}}
{{- if $p.ingressController }}{{ $kinds = add1 $kinds }}{{ end -}}
{{- if $p.internet }}{{ $kinds = add1 $kinds }}{{ end -}}
{{- if $p.metadataServer }}{{ $kinds = add1 $kinds }}{{ end -}}
{{- if ne (int $kinds) 1 -}}
{{- fail (printf "%s must declare exactly one peer kind (sameNamespace, namespace, cidr, ingressController, internet, metadataServer)" .context) -}}
{{- end -}}
{{- if $p.sameNamespace }}
{{- if $p.podLabels }}
- podSelector:
    matchLabels:
      {{- toYaml $p.podLabels | nindent 6 }}
{{- else }}
- podSelector: {}
{{- end }}
{{- else if $p.namespace }}
- namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: {{ $p.namespace | quote }}
  {{- if $p.podLabels }}
  podSelector:
    matchLabels:
      {{- toYaml $p.podLabels | nindent 6 }}
  {{- end }}
{{- else if $p.ingressController }}
- namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: ingress-nginx
{{- else if $p.cidr }}
- ipBlock:
    cidr: {{ $p.cidr | quote }}
{{- else if $p.internet }}
- ipBlock:
    cidr: 0.0.0.0/0
    except:
      - 10.0.0.0/8
      - 172.16.0.0/12
      - 192.168.0.0/16
      - 169.254.0.0/16
{{- else if $p.metadataServer }}
- ipBlock:
    cidr: 169.254.169.254/32
{{- end }}
{{- end -}}

{{- define "platform.networkPorts" -}}
{{- range . }}
- protocol: {{ .protocol | default "TCP" }}
  port: {{ .port }}
{{- end }}
{{- end -}}

{{/* Deny-by-default NetworkPolicy for the workload with typed allow rules. */}}
{{- define "platform.networkPolicy" -}}
{{- $n := .Values.network -}}
{{- $allPorts := list -}}
{{- range .Values.container.ports }}{{ $allPorts = append $allPorts (dict "port" .port "protocol" (.protocol | default "TCP")) }}{{ end -}}
{{- $ingressRules := list -}}
{{- range $n.ingress -}}
{{- $ports := .ports | default $allPorts -}}
{{- if not $ports }}{{ fail (printf "network.ingress[%s] needs ports because the workload declares no container ports" .name) }}{{ end -}}
{{- $ingressRules = append $ingressRules (dict "name" .name "purpose" .purpose "from" .from "ports" $ports) -}}
{{- end -}}
{{- if and (hasKey .Values "ingress") .Values.ingress.enabled -}}
{{- $edgePort := fromJson (include "platform.portByName" (dict "ports" .Values.container.ports "name" .Values.ingress.port "context" "ingress.port")) -}}
{{- $ingressRules = append $ingressRules (dict "name" "platform-edge" "purpose" "HTTP traffic from the platform ingress controller" "from" (dict "ingressController" true) "ports" (list (dict "port" $edgePort.port "protocol" "TCP"))) -}}
{{- end -}}
{{- if and (hasKey .Values "layer4Exposure") .Values.layer4Exposure.enabled -}}
{{- $l4 := list -}}
{{- range .Values.layer4Exposure.ports }}{{ $l4 = append $l4 (dict "port" .port "protocol" .protocol) }}{{ end -}}
{{- $ingressRules = append $ingressRules (dict "name" "public-transport" "purpose" "Public transport traffic through the dedicated layer-four load balancer" "from" (dict "cidr" "0.0.0.0/0") "ports" $l4) -}}
{{- end -}}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ include "platform.name" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "platform.labels" . | nindent 4 }}
  annotations:
    platform.yourown.chat/ingress-rules: {{ include "platform.ruleSummary" $ingressRules | quote }}
    platform.yourown.chat/egress-rules: {{ include "platform.ruleSummary" $n.egress | quote }}
spec:
  podSelector:
    matchLabels:
      {{- include "platform.selectorLabels" . | nindent 6 }}
  policyTypes: [Ingress, Egress]
  {{- if $ingressRules }}
  ingress:
    {{- range $ingressRules }}
    # {{ .name }}: {{ .purpose }}
    - from:
        {{- include "platform.networkPeer" (dict "peer" .from "context" (printf "network.ingress[%s].from" .name)) | trim | nindent 8 }}
      ports:
        {{- include "platform.networkPorts" .ports | trim | nindent 8 }}
    {{- end }}
  {{- else }}
  # No ingress rule is declared: the workload accepts no inbound traffic.
  ingress: []
  {{- end }}
  egress:
    # platform-dns: cluster DNS resolution
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
        - ipBlock:
            cidr: {{ printf "%s/32" (required "network.clusterDNSIP is a required release parameter (cluster DNS address)" $n.clusterDNSIP) | quote }}
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    {{- range $n.egress }}
    # {{ .name }}: {{ .purpose }}
    - to:
        {{- include "platform.networkPeer" (dict "peer" .to "context" (printf "network.egress[%s].to" .name)) | trim | nindent 8 }}
      ports:
        {{- include "platform.networkPorts" .ports | trim | nindent 8 }}
    {{- end }}
{{- end -}}

{{- define "platform.ruleSummary" -}}
{{- $names := list -}}
{{- range . }}{{ $names = append $names .name }}{{ end -}}
{{- join "," $names -}}
{{- end -}}

{{/* ServiceAccount with optional Workload Identity binding. */}}
{{- define "platform.serviceAccount" -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "platform.name" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "platform.labels" . | nindent 4 }}
  {{- with .Values.identity.googleServiceAccount }}
  annotations:
    iam.gke.io/gcp-service-account: {{ . | quote }}
  {{- end }}
automountServiceAccountToken: false
{{- end -}}

{{/* Secret Manager CSI provider class; values carry only logical secret references. */}}
{{- define "platform.secretProviderClass" -}}
{{- include "platform.validateSecrets" . -}}
{{- if .Values.secrets.files }}
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: {{ include "platform.name" . }}-secrets
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "platform.labels" . | nindent 4 }}
spec:
  provider: gke
  parameters:
    secrets: |
      {{- range .Values.secrets.files }}
      - resourceName: "projects/{{ $.Values.secrets.project }}/secrets/{{ .secret }}/versions/{{ .version | default "latest" }}"
        path: {{ .file | quote }}
      {{- end }}
{{- end }}
{{- end -}}

{{/* PodDisruptionBudget consistent with the declared replica model. */}}
{{- define "platform.pdb" -}}
{{- $d := .Values.runtime.disruptionBudget -}}
{{- if and $d $d.enabled }}
{{- $min := .Values.runtime.replicas -}}
{{- if and .Values.runtime.autoscaling .Values.runtime.autoscaling.enabled }}{{ $min = .Values.runtime.autoscaling.minReplicas }}{{ end -}}
{{- if .Values.runtime.paused }}{{ fail "runtime.disruptionBudget cannot be enabled while runtime.paused is true" }}{{ end -}}
{{- if lt (int $min) 2 }}{{ fail "runtime.disruptionBudget requires at least two replicas (runtime.replicas or autoscaling.minReplicas); a single replica is not highly available" }}{{ end -}}
{{- if ge (int $d.minAvailable) (int $min) }}{{ fail "runtime.disruptionBudget.minAvailable must be lower than the minimum replica count so maintenance can proceed" }}{{ end }}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "platform.name" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "platform.labels" . | nindent 4 }}
spec:
  minAvailable: {{ $d.minAvailable }}
  selector:
    matchLabels:
      {{- include "platform.selectorLabels" . | nindent 6 }}
{{- end }}
{{- end -}}
