#!/bin/bash
#
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Trap the SIGINT signal (Ctrl+C)
trap ctrl_c INT

function ctrl_c() {
    echo "Stopping the script..."
    exit 1
}

if [[ $# -ne  1 ]]; then
        echo "Usage: $0 CLUSTERNAME"
        exit
fi

export CLUSTER_NAME=$1

echo `date "+%Y/%m/%d %H:%M:%S"` "Sleeping before EFS creation"
sleep 10

## Fetch current AWS region
#TOKEN=`curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"`
#EC2_AVAIL_ZONE=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone -H "X-aws-ec2-metadata-token: $TOKEN"`

export AWS_DEFAULT_REGION=ap-southeast-2
export IPI_REGION=$AWS_DEFAULT_REGION

## Fetch the VPC where the installation must progress
#Paul This describe VPCS call was not fetching the VPC for some reason
#export VPCID=`aws ec2 describe-vpcs --region ${IPI_REGION} --query 'Vpcs[?(Tags[?contains(Key,'\'${CLUSTER_NAME}\'' )])].VpcId' --output text`
export VPCID=vpc-04fbe5a678dc3f93b
echo `date "+%Y/%m/%d %H:%M:%S"` "VPC ID = " $VPCID

## Fetch the security group for the worker EC2 instances and authorize ingress to EFS from the worker nodes
export WORKERSGID=`aws ec2 describe-security-groups --region ${IPI_REGION} --filters Name=vpc-id,Values=${VPCID} Name=tag:Name,Values='*worker*' --query "SecurityGroups[*].{ID:GroupId}[0]" --output text`
echo `date "+%Y/%m/%d %H:%M:%S"` "Workers Security Group ID = " $WORKERSGID

echo `date "+%Y/%m/%d %H:%M:%S"` "Authorizing Security group ingress"
aws ec2 authorize-security-group-ingress --group-id ${WORKERSGID} --source-group ${WORKERSGID} --protocol tcp --port 2049

echo `date "+%Y/%m/%d %H:%M:%S"` "Create EFS file system"
aws efs create-file-system --performance-mode generalPurpose --throughput-mode bursting --encrypted --tags Key=Name,Value=${CLUSTER_NAME}-efs --creation-token mas_devops.${CLUSTER_NAME}

## Wait for EFS to be "available"
echo `date "+%Y/%m/%d %H:%M:%S"` "Wait for EFS to be available"
while [[ `aws efs describe-file-systems --region ${IPI_REGION}  --creation-token mas_devops.${CLUSTER_NAME} --query 'FileSystems[0].LifeCycleState' --output text` != 'available' ]]; do sleep 10; done

## Create Mount targets and access points
EFSID=`aws efs describe-file-systems --region ${IPI_REGION}  --creation-token mas_devops.${CLUSTER_NAME} --query 'FileSystems[0].FileSystemId' --output text`
echo `date "+%Y/%m/%d %H:%M:%S"` "EFS ID created = " $EFSID

#Paul - This call was not fetching any subnet ids. According to Dan it is because the name route.nat.gateway is not valid
#PRIVATE_SUBNET_IDS=`aws ec2 describe-route-tables --region ${IPI_REGION} --filter #Name=vpc-id,Values=${VPCID} Name=route.nat-gateway-id,Values='*nat*' --query #"RouteTables[].Associations[].SubnetId" --output text`
#echo `date "+%Y/%m/%d %H:%M:%S"` "Private Subnet IDs = " $PRIVATE_SUBNET_IDS

echo `date "+%Y/%m/%d %H:%M:%S"` "Creating Mount Targets"
#for PRIVATE_SUBNET_ID in ${PRIVATE_SUBNET_IDS}; do aws efs create-mount-target --file-system-id #${EFSID} --subnet-id ${PRIVATE_SUBNET_ID} --security-groups ${WORKERSGID} --region #${IPI_REGION};# done

#Paul - Create the mount targets manually
aws efs create-mount-target --file-system-id ${EFSID} --subnet-id subnet-056188fda1c8a81ee --security-groups ${WORKERSGID} --region ${IPI_REGION}
aws efs create-mount-target --file-system-id ${EFSID} --subnet-id subnet-02224a6ccd14440e2 --security-groups ${WORKERSGID} --region ${IPI_REGION}
aws efs create-mount-target --file-system-id ${EFSID} --subnet-id subnet-0f6ec05f163985e36 --security-groups ${WORKERSGID} --region ${IPI_REGION}

echo `date "+%Y/%m/%d %H:%M:%S"` "Creating Access Point"
aws efs create-access-point --file-system-id ${EFSID} --client-token mas_devops.${CLUSTER_NAME} --posix-user Uid=10022,Gid=20000 --root-directory Path='/ocp,CreationInfo={OwnerUid=10011,OwnerGid=10000,Permissions=0755}' --region ${IPI_REGION}

## Configure a new Storage Class in OCP cluster with the create EFS
if [[ -f /root/install-dir/auth/kubeconfig ]]; then 
    echo `date "+%Y/%m/%d %H:%M:%S"` "Creating Storage class in OCP cluster"
    oc apply -f /root/.ansible/collections/ansible_collections/ibm/mas_devops/roles/ocp_efs/templates/operator-group.yml.j2 --kubeconfig /root/install-dir/auth/kubeconfig
    sed 's/{{ aws_efs_default_channel }}/stable/g;s/{{ aws_efs_source }}/redhat-operators/g;s/{{ aws_efs_source_namespace }}/openshift-marketplace/g' /root/.ansible/collections/ansible_collections/ibm/mas_devops/roles/ocp_efs/templates/efs-csi-subscription.yml.j2 > /root/install-dir/efs-csi-subscription.yml
    # Installation of the AWS EFS CSI Driver Operator creates an IAM user and also a secret aws-efs-cloud-credentials under namespace openshift-cluster-csi-drivers with the IAM accesskey and IAM secret 
    oc apply -f /root/install-dir/efs-csi-subscription.yml
    oc apply -f /root/.ansible/collections/ansible_collections/ibm/mas_devops/roles/ocp_efs/templates/efs-csi-driver.yml.j2 --kubeconfig /root/install-dir/auth/kubeconfig
    sed 's/rosa/ocp/g;s/{{ efs_id }}/'${EFSID}'/g;s/{{ efs_unique_id }}/'${CLUSTER_NAME}'/g' /root/.ansible/collections/ansible_collections/ibm/mas_devops/roles/ocp_efs/templates/efs-csi-storage-class.yml.j2 > /root/install-dir/efs-csi-storage-class.yml
    oc apply -f /root/install-dir/efs-csi-storage-class.yml --kubeconfig /root/install-dir/auth/kubeconfig
else
    echo `date "+%Y/%m/%d %H:%M:%S"` "Creating Storage class in ROSA - STS cluster"
    oc apply -f /root/.ansible/collections/ansible_collections/ibm/mas_devops/roles/ocp_efs/templates/operator-group.yml.j2 
    sed 's/{{ aws_efs_default_channel }}/stable/g;s/{{ aws_efs_source }}/redhat-operators/g;s/{{ aws_efs_source_namespace }}/openshift-marketplace/g' /root/.ansible/collections/ansible_collections/ibm/mas_devops/roles/ocp_efs/templates/efs-csi-subscription.yml.j2 > /root/install-dir/efs-csi-subscription.yml
    # Install the AWS EFS CSI Operator from Redhat
    oc apply -f /root/install-dir/efs-csi-subscription.yml
    # Installation of the AWS EFS CSI Driver Operator with STS has additional steps (https://docs.openshift.com/rosa/storage/container_storage_interface/osd-persistent-storage-aws-efs-csi.html)
    export CCOPODNAME=`oc get pod -n openshift-cloud-credential-operator -l app=cloud-credential-operator -o jsonpath='{.items[0].metadata.name}{"\n"}'`
    oc cp -c cloud-credential-operator openshift-cloud-credential-operator/$CCOPODNAME:/usr/bin/ccoctl /root/install-dir/ccoctl
    chmod 755 /root/install-dir/ccoctl
    # Get the OIDC ARN from based on 
    export OIDC_ARN=`aws iam list-open-id-connect-providers | jq -r '.OpenIDConnectProviderList[].Arn' | grep \`rosa describe cluster --cluster ${CLUSTER_NAME} --region ${IPI_REGION} -o json | jq -r .id\``
    mkdir -p /root/install-dir/credrequests
    cat > /root/install-dir/credrequests/CredentialsRequest.yaml << EOF
apiVersion: cloudcredential.openshift.io/v1
kind: CredentialsRequest
metadata:
  name: openshift-aws-efs-csi-driver
  namespace: openshift-cloud-credential-operator
spec:
  providerSpec:
    apiVersion: cloudcredential.openshift.io/v1
    kind: AWSProviderSpec
    statementEntries:
    - action:
      - elasticfilesystem:*
      effect: Allow
      resource: '*'
  secretRef:
    name: aws-efs-cloud-credentials
    namespace: openshift-cluster-csi-drivers
  serviceAccountNames:
  - aws-efs-csi-driver-operator
  - aws-efs-csi-driver-controller-sa
EOF
    /root/install-dir/ccoctl aws create-iam-roles --name=${CLUSTER_NAME} --region=${IPI_REGION} --credentials-requests-dir=/root/install-dir/credrequests/ --identity-provider-arn=$OIDC_ARN --output-dir /root/install-dir/
    if [[ -d /root/install-dir/manifests ]]; then
        oc create -f /root/install-dir/manifests/openshift-cluster-csi-drivers-aws-efs-cloud-credentials-credentials.yaml
    fi
    oc apply -f /root/.ansible/collections/ansible_collections/ibm/mas_devops/roles/ocp_efs/templates/efs-csi-driver.yml.j2 
    sed 's/{{ efs_id }}/'${EFSID}'/g;s/{{ efs_unique_id }}/'${CLUSTER_NAME}'/g' /root/.ansible/collections/ansible_collections/ibm/mas_devops/roles/ocp_efs/templates/efs-csi-storage-class.yml.j2 > /root/install-dir/efs-csi-storage-class.yml
    # For STS - Do not create a storage class until AWSEFSDriverNodeServiceControllerAvailable and AWSEFSDriverControllerServiceControllerAvailable change to a True status
    while [[ `oc get clustercsidriver -o json | jq -r '.items[]| select (.metadata.name == "efs.csi.aws.com") | .status.conditions[] | select (.type == "AWSEFSDriverNodeServiceControllerAvailable" ) | .status '` != "True" || `oc get clustercsidriver -o json | jq -r '.items[]| select (.metadata.name == "efs.csi.aws.com") | .status.conditions[] | select (.type == "AWSEFSDriverControllerServiceControllerAvailable" ) | .status '` != "True" ]]; do 
        echo `date "+%Y/%m/%d %H:%M:%S"` "Ignore jq error. Waiting for AWSEFSDriverNodeServiceControllerAvailable and  AWSEFSDriverControllerServiceControllerAvailable to turn to True. Sleep for 5 seconds"
        sleep 5; 
    done
    # Sleep for further 60 mins before creating the EFS storage class when using STS
    sleep 60
    oc apply -f /root/install-dir/efs-csi-storage-class.yml 
fi
exit 0

