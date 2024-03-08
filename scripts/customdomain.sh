#!/bin/bash
DOMAIN_NAME=$1
CERT_SUBJECT=$2

openssl req \
  -newkey rsa:4096 \
  -nodes \
  -sha256 \
  -keyout /var/tmp/maximo.key \
  -x509 \
  -days 365 \
  -out /var/tmp/maximo.crt \
  -subj "$CERT_SUBJECT" \
  -addext "subjectAltName = DNS:*.home.$DOMAIN_NAME, DNS:*.manage.$DOMAIN_NAME"
  
oc new-project maximo-ingress
 
oc create secret tls maximo-tls --cert=/var/tmp/maximo.crt --key=/var/tmp/maximo.key -n  maximo-ingress
 
cat <<EOF | oc create -f -
apiVersion: managed.openshift.io/v1alpha1
kind: CustomDomain
metadata:
  name: maximo-ingress
spec:
  loadBalancerType: NLB
  domain: $DOMAIN_NAME
  certificate:
    name: maximo-tls
    namespace: maximo-ingress
  scope: "Internal"
  namespaceSelector:
    matchLabels:
      ingress: maximo
EOF