# Tooling for the stack's hook Jobs: kubectl, helm, jq, curl plus openssl (CA, JWT signing) and
# ssh-keygen (Vault ssh-host-key). Pushed to the same Harbor project as the charts.
FROM alpine/k8s:1.33.4
RUN apk add --no-cache openssl openssh-keygen postgresql-client
