# KARPENTER to the existing EKS

## Usefull URLS
*  [https://rtfm.co.ua/aws-znajomstvo-z-karpenter-dlya-avtoskejlingu-v-eks-ta-vstanovlennya-z-helm-chartu/](https://rtfm.co.ua/aws-znajomstvo-z-karpenter-dlya-avtoskejlingu-v-eks-ta-vstanovlennya-z-helm-chartu/)
* [https://dhruv-mavani.medium.com/implementing-karpenter-on-eks-and-autoscaling-your-cluster-for-optimal-performance-f01a507a8f70](https://dhruv-mavani.medium.com/implementing-karpenter-on-eks-and-autoscaling-your-cluster-for-optimal-performance-f01a507a8f70)
* [https://github.com/aws/karpenter-provider-aws/tree/main/charts/karpenter](https://github.com/aws/karpenter-provider-aws/tree/main/charts/karpenter)
* [https://karpenter.sh/docs/](https://karpenter.sh/docs/)

## Prerequisites

- AWS CLI and kubectl installed and configured
- Helm installed
- Terraform - for IAM role and policy setup
- Existing EKS cluster setup
- Existing VPC and subnets
- Existing security groups
- Nodes in one or more node groups
- [OIDC provider](https://docs.aws.amazon.com/eks/latest/userguide/enable-iam-roles-for-service-accounts.html) for service accounts in your cluster

## ENV vars

```
KARPENTER_NAMESPACE=kube-system
CLUSTER_NAME=<your cluster name>

AWS_PARTITION="aws"
AWS_REGION="$(aws configure list | grep region | tr -s " " | cut -d" " -f3)"
OIDC_ENDPOINT="$(aws eks describe-cluster --name "${CLUSTER_NAME}" \
    --query "cluster.identity.oidc.issuer" --output text)"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' \
    --output text)
K8S_VERSION=1.31
ARM_AMI_ID="$(aws ssm get-parameter --name /aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2-arm64/recommended/image_id --query Parameter.Value --output text)"
AMD_AMI_ID="$(aws ssm get-parameter --name /aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2/recommended/image_id --query Parameter.Value --output text)"
GPU_AMI_ID="$(aws ssm get-parameter --name /aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2-gpu/recommended/image_id --query Parameter.Value --output text)"
```

## TAGs

It's possible to tag first time manually. We need to tag SG and Subnets(optionally)
```
for NODEGROUP in $(aws eks list-nodegroups --cluster-name "${CLUSTER_NAME}" --query 'nodegroups' --output text); do
    aws ec2 create-tags \
        --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" \
        --resources $(aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" \
        --nodegroup-name "${NODEGROUP}" --query 'nodegroup.subnets' --output text )
done

NODEGROUP=$(aws eks list-nodegroups --cluster-name "${CLUSTER_NAME}" \
    --query 'nodegroups[0]' --output text) 
## Pay attention - if you have more then 1 NG - use appropriate

LAUNCH_TEMPLATE=$(aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" \
    --nodegroup-name "${NODEGROUP}" --query 'nodegroup.launchTemplate.{id:id,version:version}' \
    --output text | tr -s "\t" ",")

# For EKS setups using only Cluster security group:
SECURITY_GROUPS=$(aws eks describe-cluster \
    --name "${CLUSTER_NAME}" --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)

# For setups using security groups in the Launch template of a managed node group:
SECURITY_GROUPS="$(aws ec2 describe-launch-template-versions \
    --launch-template-id "${LAUNCH_TEMPLATE%,*}" --versions "${LAUNCH_TEMPLATE#*,}" \
    --query 'LaunchTemplateVersions[0].LaunchTemplateData.[NetworkInterfaces[0].Groups||SecurityGroupIds]' \
    --output text)"

aws ec2 create-tags \
    --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" \
    --resources "${SECURITY_GROUPS}"
``` 


## Create iam roles with terraform

We need to have 2 roles:KarpenterInstanceNodeRole and KarpenterControllerRole

``` 
terraform init
terraform apply
```

## Update auth-map

1. backup
```
kubectl -n kube-system get configmap aws-auth -o yaml > aws-auth-bkp.yaml
```
2. update to:
```
apiVersion: v1
data:
  mapRoles: |
    - groups:
      - system:bootstrappers
      - system:nodes
      rolearn: arn:aws:iam::AWS_ACCOUNT:role/default_node_group-eks-node-group-20230418184314498900000004
      username: system:node:{{EC2PrivateDNSName}}
    - groups:
      - system:bootstrappers
      - system:nodes
      rolearn: arn:aws:iam::AWS_ACCOUNT:role/bottlerocket_default-eks-node-group-20230418184314499000000005
      username: system:node:{{EC2PrivateDNSName}}
    - groups:
      - system:bootstrappers
      - system:nodes
      rolearn: arn:aws:iam::AWS_ACCOUNT:role/KarpenterInstanceNodeRole
      username: system:node:{{EC2PrivateDNSName}}
kind: ConfigMap
```

## Deploy Karpenter

Install the Karpenter controller and its associated resources in the cluster, configuring it to work with your specific EKS setup.

```
export KARPENTER_VERSION="1.0.6"
helm template karpenter oci://public.ecr.aws/karpenter/karpenter --version "${KARPENTER_VERSION}" --namespace "${KARPENTER_NAMESPACE}" \                                   <region:us-east-1>
    --set "settings.clusterName=${CLUSTER_NAME}" \
    --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::826842160223:role/KarpenterControllerRole" \
    --set controller.resources.requests.cpu=1 \
    --set controller.resources.requests.memory=1Gi \
    --set controller.resources.limits.cpu=1 \
    --set controller.resources.limits.memory=1Gi > karpenter.yaml

```

If you have one node in nodegroup  you can see a problem when pod doesn't want to associate to the same node, so play with affinity in karpenter.yaml

```
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 1
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: karpenter.sh/nodepool
                operator: DoesNotExist
              - key: eks.amazonaws.com/nodegroup
                operator: In
                values:
                  - default_node_group-20230418193427314500000001
```
also, you can modify replicas number

apply karpenter CRD:

```
kubectl create namespace "${KARPENTER_NAMESPACE}" || true
kubectl create -f \
    "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/karpenter.sh_nodepools.yaml"
kubectl create -f \
    "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/karpenter.k8s.aws_ec2nodeclasses.yaml"
kubectl create -f \
    "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/karpenter.sh_nodeclaims.yaml"
kubectl apply -f karpenter.yaml
```

## NodePool

example:
```
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: default #can change
spec:
  template:
    spec:
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64", "arm64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"] #on-demand #prioritizes spot
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["2"]
      nodeClassRef:
        apiVersion: karpenter.k8s.aws/v1beta1
        kind: EC2NodeClass
        name: default
  limits:
    cpu: 1000
  # disruption:
  #   consolidationPolicy: WhenUnderutilized
  #   expireAfter: 720h # 30 * 24h = 720h
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 30s
---
apiVersion: karpenter.k8s.aws/v1beta1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2 # Amazon Linux 2
  role: "KarpenterInstanceNodeRole" # replace with your cluster name
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: dev-eks-cluster # replace with your cluster name
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: dev-eks-cluster # replace with your cluster name
  amiSelectorTerms:
    - id: "ami-06d9bcac32f727ddb"
#   - name: "amazon-eks-node-${K8S_VERSION}-*" # <- automatically upgrade when a new AL2 EKS Optimized AMI is released. This is unsafe for production workloads. Validate AMIs in lower environments before deploying them to production.
```


## Testing

Scale existing deployment and check karpenter pod logs, especially IAM.

