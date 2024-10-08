provider "aws" {
  region = "us-east-1" # Adjust the region as needed
}

# Create the policy for KarpenterControllerRole
resource "aws_iam_policy" "karpenter_controller_policy" {
  name        = "KarpenterControllerPolicy"
  description = "Policy for Karpenter Controller Role"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "Karpenter",
        Effect = "Allow",
        Action = [
          "ssm:GetParameter",
          "iam:PassRole",
          "iam:GetInstanceProfile",
          "iam:TagInstanceProfile",
          "iam:CreateInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "ec2:DescribeImages",
          "ec2:RunInstances",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeAvailabilityZones",
          "ec2:DeleteLaunchTemplate",
          "ec2:CreateTags",
          "ec2:CreateLaunchTemplate",
          "ec2:CreateFleet",
          "ec2:DescribeSpotPriceHistory",
          "ec2:TerminateInstances",
          "pricing:GetProducts",
          "eks:DescribeCluster"
        ],
        Resource = "*"
      },
      {
        Sid      = "ConditionalEC2Termination",
        Effect   = "Allow",
        Action   = "ec2:TerminateInstances",
        Resource = "*",
        Condition = {
          StringLike = {
            "ec2:ResourceTag/Name" = "*karpenter*"
          }
        }
      }
    ]
  })
}

# Create the KarpenterControllerRole
resource "aws_iam_role" "karpenter_controller_role" {
  name = "KarpenterControllerRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Federated = "arn:aws:iam::826842160223:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/DB9CF4A3134A38E9B6229C780E353442"
        },
        Action = "sts:AssumeRoleWithWebIdentity",
        Condition = {
          "StringEquals" = {
            "oidc.eks.us-east-1.amazonaws.com/id/DB9CF4A3134A38E9B6229C780E353442:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

# Attach the KarpenterControllerPolicy to KarpenterControllerRole
resource "aws_iam_role_policy_attachment" "karpenter_controller_policy_attachment" {
  role       = aws_iam_role.karpenter_controller_role.name
  policy_arn = aws_iam_policy.karpenter_controller_policy.arn
}

# Create the KarpenterInstanceNodeRole
resource "aws_iam_role" "karpenter_instance_node_role" {
  name = "KarpenterInstanceNodeRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Attach the managed policies to the KarpenterInstanceNodeRole
resource "aws_iam_role_policy_attachment" "karpenter_instance_node_role_attachments" {
  for_each = toset([
    "AmazonEC2ContainerRegistryReadOnly",
    "AmazonEKS_CNI_Policy",
    "AmazonEKSWorkerNodePolicy",
    "AmazonSSMManagedInstanceCore"
  ])

  role       = aws_iam_role.karpenter_instance_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/${each.value}"
}
