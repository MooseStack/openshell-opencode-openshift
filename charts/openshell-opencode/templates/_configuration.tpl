{{/* Configuration belongs in Helm; the setup script only applies it. */}}
{{- define "openshellOpencode.policy" -}}
version: 1
filesystem_policy: {{ .Values.sandbox.filesystemPolicy | toJson }}
landlock: {{ .Values.sandbox.landlock | toJson }}
{{- with .Values.sandbox.process }}
process: {{ . | toJson }}
{{- end }}
{{- with .Values.sandbox.networkMiddlewares }}
network_middlewares: {{ . | toJson }}
{{- end }}
network_policies: {{ .Values.sandbox.networkPolicies | toJson }}
{{- end -}}

{{- define "openshellOpencode.profile" -}}
{{- $url := urlParse .Values.model.baseURL -}}
{{- $host := regexReplaceAll ":[0-9]+$" $url.host "" | trimPrefix "[" | trimSuffix "]" -}}
{{- $port := regexFind ":[0-9]+$" $url.host | trimPrefix ":" | default "443" | int -}}
{{- if or (lt $port 1) (gt $port 65535) -}}{{ fail "model.baseURL port must be between 1 and 65535" }}{{- end -}}
id: {{ printf "%s-llm" .Values.sandbox.name | quote }}
display_name: Configured model
category: inference
inference_capable: true
credentials:
  - name: api_key
    env_vars: [LLM_API_KEY]
    required: true
    auth_style: bearer
    header_name: authorization
    stable_placeholder: true
discovery:
  credentials: [api_key]
endpoints:
  - host: {{ $host | quote }}
    port: {{ $port }}
    path: {{ printf "%s/**" (regexReplaceAll "/+$" $url.path "") | quote }}
    protocol: rest
    access: read-write
    enforcement: enforce
    {{- with .Values.model.allowedIPs }}
    allowed_ips: {{ . | toJson }}
    {{- end }}
binaries: [/usr/local/bin/opencode]
{{- end -}}

{{- define "openshellOpencode.opencode" -}}
$schema: https://opencode.ai/config.json
autoupdate: false
enabled_providers: [custom]
model: {{ printf "custom/%s" .Values.model.id | quote }}
small_model: {{ printf "custom/%s" .Values.model.id | quote }}
provider:
  custom:
    npm: '@ai-sdk/openai-compatible'
    name: Configured endpoint
    options:
      baseURL: {{ regexReplaceAll "/+$" .Values.model.baseURL "" | quote }}
      apiKey: '{env:LLM_API_KEY}'
    models:
      {{ .Values.model.id | quote }}:
        name: {{ .Values.model.id | quote }}
{{- end -}}
