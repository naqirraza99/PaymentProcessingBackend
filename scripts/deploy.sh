
#!/bin/bash

set -e  # Exit immediately if a command fails
set -o pipefail  # Fail on any error in a pipeline

# Variables
AWS_REGION="us-east-1"
VPC_CIDR="10.0.0.0/16"
SUBNET_PUBLIC_A_CIDR="10.0.1.0/24"
SUBNET_PUBLIC_B_CIDR="10.0.3.0/24"
SUBNET_PRIVATE_A_CIDR="10.0.2.0/24"
SUBNET_PRIVATE_B_CIDR="10.0.4.0/24"
SECURITY_GROUP_NAME="payment-api-sg"
ALB_NAME="payment-api-alb"
TARGET_GROUP_NAME="payment-api-target-group"
INSTANCE_TYPE="t3.small"
KEY_NAME="payment-key"
AMI_ID=$(cat ami-id.txt)  # Read AMI ID from the file created by build-ami.sh

# Log file
LOG_FILE="deploy.log"
echo "🚀 Starting Deployment..." | tee $LOG_FILE

# === VPC Creation ===
echo "🔍 Checking for existing VPC..."
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=cidr-block,Values=$VPC_CIDR" --query "Vpcs[0].VpcId" --output text 2>/dev/null || true)

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
    echo "🚀 Creating VPC..."
    VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR --query 'Vpc.VpcId' --output text)
    aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support "{\"Value\":true}"
    aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames "{\"Value\":true}"
    echo "✅ VPC Created: $VPC_ID" | tee -a $LOG_FILE
else
    echo "✅ Using existing VPC: $VPC_ID" | tee -a $LOG_FILE
fi

# === Subnet Creation ===
echo "🔍 Creating Subnets..."
SUBNET_PUBLIC_A=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_PUBLIC_A_CIDR --availability-zone us-east-1a --query 'Subnet.SubnetId' --output text)
SUBNET_PUBLIC_B=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_PUBLIC_B_CIDR --availability-zone us-east-1b --query 'Subnet.SubnetId' --output text)
SUBNET_PRIVATE_A=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_PRIVATE_A_CIDR --availability-zone us-east-1a --query 'Subnet.SubnetId' --output text)
SUBNET_PRIVATE_B=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_PRIVATE_B_CIDR --availability-zone us-east-1b --query 'Subnet.SubnetId' --output text)
echo "✅ Subnets Created: PublicA=$SUBNET_PUBLIC_A, PublicB=$SUBNET_PUBLIC_B, PrivateA=$SUBNET_PRIVATE_A, PrivateB=$SUBNET_PRIVATE_B" | tee -a $LOG_FILE

# === Internet Gateway Creation ===
echo "🔍 Creating Internet Gateway..."
IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
echo "✅ Internet Gateway Created: $IGW_ID" | tee -a $LOG_FILE

# === Route Table Configuration ===
echo "🔍 Configuring Route Tables..."
RT_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $RT_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
aws ec2 associate-route-table --route-table-id $RT_ID --subnet-id $SUBNET_PUBLIC_A
aws ec2 associate-route-table --route-table-id $RT_ID --subnet-id $SUBNET_PUBLIC_B
echo "✅ Route Table Configured: $RT_ID" | tee -a $LOG_FILE

# === Security Group Creation ===
echo "🔍 Creating Security Groups..."
ALB_SG_ID=$(aws ec2 create-security-group --group-name "ALB-SG" --description "Security Group for ALB" --vpc-id $VPC_ID --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $ALB_SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $ALB_SG_ID --protocol tcp --port 443 --cidr 0.0.0.0/0
echo "✅ ALB Security Group Created: $ALB_SG_ID" | tee -a $LOG_FILE

EC2_SG_ID=$(aws ec2 create-security-group --group-name "EC2-SG" --description "Security Group for EC2 Instances" --vpc-id $VPC_ID --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $EC2_SG_ID --protocol tcp --port 80 --source-group $ALB_SG_ID
aws ec2 authorize-security-group-ingress --group-id $EC2_SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0
echo "✅ EC2 Security Group Created: $EC2_SG_ID" | tee -a $LOG_FILE

# === EC2 Instance Deployment ===
echo "🚀 Launching EC2 Instances..."
INSTANCE_1=$(aws ec2 run-instances --image-id $AMI_ID --instance-type $INSTANCE_TYPE --key-name $KEY_NAME --security-group-ids $EC2_SG_ID --subnet-id $SUBNET_PRIVATE_A --query 'Instances[0].InstanceId' --output text)
INSTANCE_2=$(aws ec2 run-instances --image-id $AMI_ID --instance-type $INSTANCE_TYPE --key-name $KEY_NAME --security-group-ids $EC2_SG_ID --subnet-id $SUBNET_PRIVATE_B --query 'Instances[0].InstanceId' --output text)
echo "✅ EC2 Instances Launched: $INSTANCE_1, $INSTANCE_2" | tee -a $LOG_FILE

# === Application Load Balancer (ALB) Creation ===
echo "🔍 Creating Application Load Balancer..."
ALB_ARN=$(aws elbv2 create-load-balancer --name $ALB_NAME --subnets $SUBNET_PUBLIC_A $SUBNET_PUBLIC_B --security-groups $ALB_SG_ID --query 'LoadBalancers[0].LoadBalancerArn' --output text)
echo "✅ ALB Created: $ALB_ARN" | tee -a $LOG_FILE

# === Target Group Creation ===
echo "🔍 Creating Target Group..."
TARGET_GROUP_ARN=$(aws elbv2 create-target-group --name $TARGET_GROUP_NAME --protocol HTTP --port 80 --vpc-id $VPC_ID --query 'TargetGroups[0].TargetGroupArn' --output text)
echo "✅ Target Group Created: $TARGET_GROUP_ARN" | tee -a $LOG_FILE

# === Register EC2 Instances with Target Group ===
echo "🔍 Registering EC2 Instances with Target Group..."
aws elbv2 register-targets --target-group-arn $TARGET_GROUP_ARN --targets Id=$INSTANCE_1 Id=$INSTANCE_2
echo "✅ EC2 Instances Registered with Target Group" | tee -a $LOG_FILE

# === ALB Listener Creation ===
echo "🔍 Creating ALB Listener..."
aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn=$TARGET_GROUP_ARN
echo "✅ ALB Listener Created" | tee -a $LOG_FILE

# === Final Output ===
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --query 'LoadBalancers[0].DNSName' --output text)
echo "🌐 ALB DNS Name: http://$ALB_DNS" | tee -a $LOG_FILE
echo "✅ Deployment Complete!" | tee -a $LOG_FILE
