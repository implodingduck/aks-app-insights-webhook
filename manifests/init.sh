#!/bin/bash

set -e
title="app-insights-webhook"
namespace="kube-system"

[ -z ${title} ] && title=app-insights-webhook
[ -z ${namespace} ] && namespace=kube-system

if [ ! -x "$(command -v openssl)" ]; then
    echo "openssl not found"
    exit 1
fi

csrName=${title}.${namespace}
tmpdir=$(mktemp -d)
echo "creating certs in tmpdir ${tmpdir} "

cat <<EOF >> ${tmpdir}/csr.conf
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${title}
DNS.2 = ${title}.${namespace}
DNS.3 = ${title}.${namespace}.svc
DNS.4 = ${namespace}.svc
EOF

openssl genrsa -out ${tmpdir}/server-key.pem 2048
openssl req -new -key ${tmpdir}/server-key.pem -subj "/CN=system:node:${title}.${namespace}.svc/OU=system:nodes/O=system:nodes" -out ${tmpdir}/server.csr -config ${tmpdir}/csr.conf

# clean-up any previously created CSR for our service. Ignore errors if not present.
echo "delete previous csr certs if they exist"
kubectl delete csr ${csrName} 2>/dev/null || true

# create server cert/key CSR and send to k8s API
echo "create server cert/key CSR and send to k8s API"
cat <<EOF | kubectl create -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${csrName}
spec:
  groups:
  - system:authenticated
  request: $(cat ${tmpdir}/server.csr | base64 | tr -d '\n')
  signerName: kubernetes.io/kubelet-serving
  usages:
  - digital signature
  - key encipherment
  - server auth
EOF

# verify CSR has been created
echo "verify CSR has been created"
while true; do
    kubectl get csr ${csrName}
    if [ "$?" -eq 0 ]; then
        break
    fi
done

# approve and fetch the signed certificate
echo "approve and fetch the signed certificate"
kubectl certificate approve ${csrName}
# verify certificate has been signed

for x in $(seq 20); do
    serverCert=$(kubectl get csr ${csrName} -o jsonpath='{.status.certificate}')
    if [[ ${serverCert} != '' ]]; then
        break
    fi
    sleep 1
done
if [[ ${serverCert} == '' ]]; then
    echo "ERROR: After approving csr ${csrName}, the signed certificate did not appear on the resource. Giving up after 20 attempts." >&2
    exit 1
fi
echo ${serverCert} | openssl base64 -d -A -out ${tmpdir}/server-cert.pem

# create the secret with CA cert and server cert/key
echo "create the secret with CA cert and server cert/key"
kubectl create secret generic ${title} \
        --from-file=key.pem=${tmpdir}/server-key.pem \
        --from-file=cert.pem=${tmpdir}/server-cert.pem \
        --dry-run=client -o yaml |
    kubectl -n ${namespace} apply -f -

export CA_BUNDLE=$(kubectl get configmap -n kube-system extension-apiserver-authentication -o=jsonpath='{.data.client-ca-file}' | base64 | tr -d '\n')
#cat ./values._aml | envsubst > ./values.yaml

cat <<EOF > ./0-secrets.yaml
apiVersion: v1
data:
  iConnectionString: "REPLACE_ME"
kind: Secret
metadata:
  name: ${title}-secrets
  namespace: ${namespace}
type: Opaque
EOF

cat <<EOF > ./3-webhook.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: app-insights-webhook
  namespace: kube-system
  labels:
    app: app-insights-webhook
webhooks:
- admissionReviewVersions: ["v1"]
  name: app-insights-webhook.azmk8s.io
  clientConfig:
    caBundle: ${CA_BUNDLE}
    service:
      name: app-insights-webhook
      namespace: kube-system
      path: "/"
      port: 443
  rules:
    - operations: ["CREATE"]
      apiGroups: [""]
      apiVersions: ["v1"]
      resources: ["pods"]
  sideEffects: None
  failurePolicy: Ignore
EOF