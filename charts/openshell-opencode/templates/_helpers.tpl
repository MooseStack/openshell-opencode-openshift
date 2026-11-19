{{- define "openshellOpencode.name" -}}
{{- .Release.Name | trunc 50 | trimSuffix "-" -}}
{{- end -}}

{{- define "openshellOpencode.validate" -}}
{{- $url := required "Set model.baseURL to your HTTPS OpenAI-compatible API base URL" .Values.model.baseURL -}}
{{- $_ := required "Set model.id to the model ID served by your endpoint" .Values.model.id -}}
{{- if not (hasPrefix "https://" $url) -}}{{ fail "model.baseURL must use HTTPS for credential injection" }}{{- end -}}
{{- $parsed := urlParse $url -}}
{{- if or $parsed.userinfo $parsed.query $parsed.fragment (not $parsed.host) -}}
{{- fail "model.baseURL must have a host and no credentials, query, or fragment" -}}
{{- end -}}
{{- if ne .Values.setup.cliVersion .Chart.AppVersion -}}{{ fail "setup.cliVersion must match the pinned OpenShell chart version" }}{{- end -}}
{{- if or .Values.openshell.server.disableTls (not .Values.openshell.server.tls.enableMtls) .Values.openshell.server.auth.allowUnauthenticatedUsers -}}
{{- fail "This deployment's setup and connection workflow requires TLS and mTLS authentication" -}}
{{- end -}}
{{- end -}}
