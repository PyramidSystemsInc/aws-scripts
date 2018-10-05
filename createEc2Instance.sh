#! /bin/bash

# Add a meaningful name to the EC2 instance
function changeInstanceName() {
  aws ec2 create-tags --region $AWS_REGION --resources "$INSTANCE_ID" --tags Key=Name,Value="$INSTANCE_NAME"
  echo "STEPS_COMPLETED[4]=true" | sudo tee --append /configurationProgress.sh >> /dev/null
}

# Create EC2 instance
function createInstance() {
  COMMAND="aws ec2 run-instances --region "$AWS_REGION" --image-id "$AWS_IMAGE_AMI" --count "$COUNT" --instance-type "$AWS_INSTANCE_TYPE" --key-name "$INSTANCE_NAME" --security-group-ids "$SECURITY_GROUP_ID""
  if [ -n "$AWS_IAM_ROLE" ]; then
    COMMAND+=" --iam-instance-profile Name="$AWS_IAM_ROLE""
  fi
  if [ -n "$VOLUME_SIZE" ]; then
    COMMAND+=" --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":$VOLUME_SIZE}}]""
  fi
  if [ -n "$STARTUP_SCRIPT" ]; then
    COMMAND+=" --user-data file://$STARTUP_SCRIPT"
  fi
  INSTANCE_ID=$(sed -e 's/^"//' -e 's/"$//' <<< $($COMMAND | jq '.Instances[0].InstanceId'))
  echo "STEPS_COMPLETED[3]=true" | sudo tee --append /configurationProgress.sh >> /dev/null
}

# Create key pair
function createKeyPair() {
  if [ -f "$KEY_PAIR_DIR""$INSTANCE_NAME".pem ]; then
    sudo rm "$KEY_PAIR_DIR""$INSTANCE_NAME".pem
  fi
  aws ec2 create-key-pair --region $AWS_REGION --key-name "$INSTANCE_NAME" --query 'KeyMaterial' --output text > "$KEY_PAIR_DIR""$INSTANCE_NAME".pem
  KEY_PAIR=$(cat "$KEY_PAIR_DIR""$INSTANCE_NAME".pem)
  if [ ${#KEY_PAIR} == 0 ]; then
    echo -e ""
    echo -e "${COLOR_RED}ERROR: PEM file was unable to be created. Do you have permissions on your AWS account to create key pairs?"
    echo -e "${COLOR_NONE}"
    if pgrep $MONITOR_PROGRESS_PID; then pkill $MONITOR_PROGRESS_PID; fi
    exit 2
  else
    chmod 400 "$KEY_PAIR_DIR""$INSTANCE_NAME".pem
  fi
  echo "STEPS_COMPLETED[2]=true" | sudo tee --append /configurationProgress.sh >> /dev/null
}

# Create security group
function createSecurityGroup() {
  SECURITY_GROUP_ID=$(sed -e 's/^"//' -e 's/"$//' <<< "$(aws ec2 create-security-group --region $AWS_REGION --group-name "$INSTANCE_NAME" --description "Created using AWS scripts for instance of the same name" | jq '.GroupId')")
  for PORT in "${PORTS[@]}"; do
    aws ec2 authorize-security-group-ingress --region $AWS_REGION --group-id "$SECURITY_GROUP_ID" --protocol tcp --port $PORT --cidr 0.0.0.0/0
  done
  echo "STEPS_COMPLETED[1]=true" | sudo tee --append /configurationProgress.sh >> /dev/null
}

# Define all colors used for output
function defineColorPalette() {
  COLOR_RED='\033[0;91m'
  COLOR_WHITE_BOLD='\033[1;97m'
  COLOR_NONE='\033[0m'
}

# Create the configuration variable needed for the monitorProgress.sh script
function defineExpectedProgress() {
  if [ $WAIT_FOR_INITIALIZATION == "true" ]; then
		EXPECTED_PROGRESS=$(cat <<-EOF
			[
			  "Creating EC2 Instance",
			  "Creating Security Group",
			  "Creating Key Pair",
			  "Creating Instance",
			  "Changing Instance Name",
        "Initializing Instance and Running Startup Script (if supplied)"
			]
		EOF
		)
  else
		EXPECTED_PROGRESS=$(cat <<-EOF
			[
			  "Creating EC2 Instance",
			  "Creating Security Group",
			  "Creating Key Pair",
			  "Creating Instance",
			  "Changing Instance Name"
			]
		EOF
		)
  fi
}

# Handle user input
function handleInput() {
  AWS_REGION="us-east-2"
  COUNT=1
  KEY_PAIR_DIR="/home/$(whoami)/Desktop/"
  PORTS=()
  TAG_NAMES=()
  TAG_VALUES=()
  WAIT_FOR_INITIALIZATION=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      # Required inputs
      --name) INSTANCE_NAME=$2; shift 2;;
      --image) AWS_IMAGE_AMI=$2; shift 2;;
      --type) AWS_INSTANCE_TYPE=$2; shift 2;;
      # Optional inputs
      --iam-role) AWS_IAM_ROLE="$2"; shift 2;;
      --key-pair-dir) KEY_PAIR_DIR="$2"; shift 2;;
      --port) PORTS+=("$2"); shift 2;;
      --region) AWS_REGION="$2"; shift 2;;
      --startup-script) STARTUP_SCRIPT="$2"; shift 2;;
      --volume-size) VOLUME_SIZE=$2; shift 2;;
      --wait-for-init) WAIT_FOR_INITIALIZATION=true; shift 1;;
      # Optional inputs yet to be implemented
      --tag) TAG=$2; shift 2;;
      --count) COUNT=$2; shift 2;;
      --skip-output) NO_OUTPUT=true; shift 1;;
      -h) HELP_WANTED=true; shift 1;;
      --help) HELP_WANTED=true; shift 1;;
      -*) echo "unknown option: $1" >&2; exit 1;;
      *) args+="$1 "; shift 1;;
    esac
  done
  if [ ${#args} -gt 0 ]; then
    echo -e "${COLOR_WHITE_BOLD}NOTICE: The following arguments were ignored: ${args}"
    echo -e "${COLOR_NONE}"
  fi
}

# Print confirmation that the instance is now running and passes all status checks
function printAdditionalInformation() {
  AWS_INSTANCE_DESCRIPTION=$(aws ec2 describe-instances --region $AWS_REGION --instance-ids $INSTANCE_ID | jq '.Reservations[0].Instances[0]')
  INSTANCE_PUBLIC_DNS=$(sed -e 's/^"//' -e 's/"$//' <<< $(echo $AWS_INSTANCE_DESCRIPTION | jq '.PublicDnsName'))
  INSTANCE_PUBLIC_IP=$(sed -e 's/^"//' -e 's/"$//' <<< $(echo $AWS_INSTANCE_DESCRIPTION | jq '.PublicIpAddress'))
  echo -e ""
  echo -e "${COLOR_WHITE_BOLD}NOTICE: Instance Information:"
  echo -e "${COLOR_WHITE_BOLD}    Login Command:${COLOR_NONE} ssh -i $KEY_PAIR_DIR$INSTANCE_NAME.pem ec2-user@$INSTANCE_PUBLIC_DNS"
  echo -e "${COLOR_WHITE_BOLD}    Instance ID:${COLOR_NONE} $INSTANCE_ID"
  echo -e "${COLOR_WHITE_BOLD}    Public IP Address:${COLOR_NONE} $INSTANCE_PUBLIC_IP"
  echo -e "${COLOR_NONE}"
}

# Query the instances' status until all status checks pass
function waitUntilInstanceInitialized() {
  if [ $WAIT_FOR_INITIALIZATION == "true" ]; then
    while : ; do
      AWS_INSTANCE_STATUS=$(aws ec2 describe-instance-status --region $AWS_REGION --instance-ids $INSTANCE_ID)
      SYSTEM_STATUS=$(echo "$AWS_INSTANCE_STATUS" | jq '.InstanceStatuses[0].SystemStatus.Status')
      INSTANCE_STATUS=$(echo "$AWS_INSTANCE_STATUS" | jq '.InstanceStatuses[0].InstanceStatus.Status')
      if [ "$SYSTEM_STATUS" == "\"ok\"" ] && [ "$INSTANCE_STATUS" == "\"ok\"" ]; then
        break
      else
        sleep 2
      fi
    done
    echo "STEPS_COMPLETED[5]=true" | sudo tee --append /configurationProgress.sh >> /dev/null
  fi
}

function waitUntilInstanceRunning() {
  aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
}

handleInput "$@"
defineColorPalette
#defineExpectedProgress
#trap 'kill $MONITOR_PROGRESS_PID; exit' SIGINT; ./monitorProgress.sh "$EXPECTED_PROGRESS" & MONITOR_PROGRESS_PID=$!
createSecurityGroup
createKeyPair
createInstance
changeInstanceName
waitUntilInstanceRunning
waitUntilInstanceInitialized
#sleep 3; if pgrep $MONITOR_PROGRESS_PID; then pkill $MONITOR_PROGRESS_PID; fi
printAdditionalInformation
