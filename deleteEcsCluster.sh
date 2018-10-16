#! /bin/bash

function startMonitoringProgress() {
  defineExpectedProgress
  PROGRESS_FILE=$(mktemp /tmp/monitor-progress.XXXXXXX)
  sudo chmod 775 "$PROGRESS_FILE"
  trap 'stopMonitoringProgress; exit' SIGINT; ./util/monitorProgress.sh "$PROGRESS_FILE" "$EXPECTED_PROGRESS" & MONITOR_PROGRESS_PID=$!
  echo "declare -A STEPS_COMPLETED" | sudo tee --append "$PROGRESS_FILE" >> /dev/null
}

function stopMonitoringProgress() {
  sleep 2
  STILL_MONITORING_PROGRESS=$(ps -a | grep $MONITOR_PROGRESS_PID)
  if [ ! "$STILL_MONITORING_PROGRESS" == "" ]; then
    kill $MONITOR_PROGRESS_PID >/dev/null 2>/dev/null
  fi
  if [ -f "$PROGRESS_FILE" ]; then
    rm -Rf "$PROGRESS_FILE"
  fi
}

# Declare defaults for optional input values / flags
function declareInputDefaults() {
  AWS_REGION="us-east-2"
}

# Define all colors used for output
function defineColorPalette() {
  COLOR_BLUE='\033[0;34m'
	COLOR_GREEN='\033[0;32m'
  COLOR_RED='\033[0;91m'
  COLOR_WHITE='\033[0;97m'
  COLOR_WHITE_BOLD='\033[1;97m'
  COLOR_NONE='\033[0m'
}

# Handle user input
function handleInput() {
  declareInputDefaults
  parseInputFlags "$@"
  showHelp
  notifyUserOfUnknownInputArgs
}

# If the user provides input the script does not understand, show them which part is being ignored
function notifyUserOfUnknownInputArgs() {
  if [ ${#ARGS} -gt 0 ]; then
    echo -e "${COLOR_WHITE_BOLD}NOTICE: The following arguments were ignored: ${ARGS}"
    echo -e "${COLOR_NONE}"
  fi
}

# Divide the user input into variables
function parseInputFlags() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      # Required inputs
      -c) CLUSTER_NAME="$2"; shift 2;;
      --cluster) CLUSTER_NAME="$2"; shift 2;;
      # Optional inputs
      -r) AWS_REGION="$2"; shift 2;;
      --region) AWS_REGION="$2"; shift 2;;
      # Optional inputs yet to be implemented
      -s) NO_OUTPUT=true; shift 1;;
      --skip-output) NO_OUTPUT=true; shift 1;;
      -h) HELP_WANTED=true; shift 1;;
      --help) HELP_WANTED=true; shift 1;;
      -*) echo "unknown option: $1" >&2; exit 1;;
      *) ARGS+="$1 "; shift 1;;
    esac
  done
}

function showHelp() {
	if [ "$HELP_WANTED" == "true" ]; then
    echo -e ""
    echo -e "Usage: ./deleteEcsCluster.sh --cluster <CLUSTER_NAME> [OPTIONS]"
    echo -e ""
    echo -e "Delete an ECS cluster by name and terminate all of the EC2 resources it was using"
    echo -e ""
    echo -e "Options:"
    echo -e "  -c,  --cluster <string>                  Name of the ECS cluster you want to delete. ${COLOR_GREEN}(required)${COLOR_NONE}"
    echo -e "  -h, --help                               Shows this block of text. Specifying the help flag will abort deletion of AWS"
    echo -e "                                             resources"
    echo -e "  -r, --region <string>                    AWS region where your cluster exists. Defaults to 'us-east-2'"
    echo -e "  -s, --skip-output                        Suppress all output including errors"
    echo -e ""
    echo -e "Examples:"
    echo -e "$ ./deleteEcsCluster.sh --cluster sample -s"
    echo -e "    * Deletes the sample cluster and all of its EC2 resources"
    echo -e "    * Command will give zero output"
    echo -e ""
    echo -e "$ ./deleteEcsCluster.sh -c cluster -r us-east-1"
    echo -e "    * Deletes the cluster named 'cluster' in the Northern Virginia AWS region"
    echo -e ""
    echo -e "Having trouble?"
    echo -e "  Please send any questions or issues to jdiederiks@psi-it.com"
    echo -e ""
    exit 2
  fi
}

# Terminate EC2 instances registered to the specified cluster, then wait until they are terminated
function terminateEc2Instances() {
  sendTerminateOrderToEc2Instances
  waitUntilEc2InstancesTerminated
}

# Delete the ECS cluster
function deleteEcsCluster() {
  DELETE_CLUSTER=$(aws ecs delete-cluster --cluster "$CLUSTER_NAME" --region "$AWS_REGION")
  echo "STEPS_COMPLETED[delete-cluster]=true" | sudo tee --append "$PROGRESS_FILE" >> /dev/null
}

# Get all the EC2 instance IDs of the container instances in the ECS cluster specified
function getEc2InstanceIdsInCluster() {
  EC2_INSTANCE_IDS=()
  getContainerInstanceIdsInCluster
  if [ "${#CONTAINER_INSTANCE_IDS[@]}" -gt 0 ]; then
    CONTAINER_INSTANCE_DESCRIPTIONS=$(aws ecs describe-container-instances --cluster "$CLUSTER_NAME" --container-instances "${CONTAINER_INSTANCE_IDS[@]}" --query 'containerInstances[*].ec2InstanceId' --region "$AWS_REGION")
    DESCRIPTION_COUNT=$(echo "$CONTAINER_INSTANCE_DESCRIPTIONS" | jq '. | length')
    for (( DESCRIPTION_INDEX=0; DESCRIPTION_INDEX<DESCRIPTION_COUNT; DESCRIPTION_INDEX++ )); do
      EC2_INSTANCE_IDS+=($(sed -e 's/^"//' -e 's/"$//' <<< $(echo "$CONTAINER_INSTANCE_DESCRIPTIONS" | jq '.['"$DESCRIPTION_INDEX"']')))
    done
  fi
  echo "STEPS_COMPLETED[get-instance-ids]=true" | sudo tee --append "$PROGRESS_FILE" >> /dev/null
}

# Get the ECS container instance IDs in the cluster
function getContainerInstanceIdsInCluster() {
  CONTAINER_INSTANCE_IDS=()
  CONTAINER_INSTANCES=$(aws ecs list-container-instances --cluster "$CLUSTER_NAME" --region "$AWS_REGION" | jq '.containerInstanceArns')
  CONTAINER_INSTANCE_COUNT=$(echo "$CONTAINER_INSTANCES" | jq '. | length')
  for (( CONTAINER_INSTANCE_INDEX=0; CONTAINER_INSTANCE_INDEX<CONTAINER_INSTANCE_COUNT; CONTAINER_INSTANCE_INDEX++ )); do
    THIS_CONTAINER_INSTANCE=$(sed -e 's/^.*\///' -e 's/"$//' <<< $(echo "$CONTAINER_INSTANCES" | jq '.['"$CONTAINER_INSTANCE_INDEX"']'))
    CONTAINER_INSTANCE_IDS+=("$THIS_CONTAINER_INSTANCE")
  done
  echo "STEPS_COMPLETED[launch-ec2-instance]=true" | sudo tee --append "$PROGRESS_FILE" >> /dev/null
}

# If instances exist in the cluster specified, send the order to start terminating all of them
function sendTerminateOrderToEc2Instances() {
  if [ "${#EC2_INSTANCE_IDS[@]}" -gt 0 ]; then
    TERMINATION_ORDER=$(aws ec2 terminate-instances --instance-ids "${EC2_INSTANCE_IDS[@]}" --region "$AWS_REGION")
  fi
  echo "STEPS_COMPLETED[send-terminate-order]=true" | sudo tee --append "$PROGRESS_FILE" >> /dev/null
}

# Wait until all the EC2 instances are finished shutting down
function waitUntilEc2InstancesTerminated() {
  INSTANCE_COUNT="${#EC2_INSTANCE_IDS[@]}"
  RUNNING_INSTANCE_COUNT="${#EC2_INSTANCE_IDS[@]}"
  while [ $RUNNING_INSTANCE_COUNT -gt 0 ]; do
    RUNNING_INSTANCE_COUNT=0
    INSTANCE_STATES=$(aws ec2 describe-instances --instance-id "${EC2_INSTANCE_IDS[@]}" --query 'Reservations[*].Instances[*].State.Name' --region "$AWS_REGION" | jq '.')
    for (( INSTANCE_INDEX=0; INSTANCE_INDEX<INSTANCE_COUNT; INSTANCE_INDEX++ )); do
      THIS_INSTANCE_STATE=$(echo "$INSTANCE_STATES" | jq '.['"$INSTANCE_INDEX"'][0]')
      if [ ! "$THIS_INSTANCE_STATE" == "\"terminated\"" ]; then
        ((RUNNING_INSTANCE_COUNT++))
      fi
    done
    if [ $RUNNING_INSTANCE_COUNT -gt 0 ]; then
      sleep 2
    fi
  done
  echo "STEPS_COMPLETED[wait-for-termination]=true" | sudo tee --append "$PROGRESS_FILE" >> /dev/null
}

# Get all the IDs of the EC2 resources used by the cluster
function getEc2ResourcesInCluster() {
  getEc2InstanceIdsInCluster
  EC2_RESOURCES=$(aws ec2 describe-instances --instance-ids "${EC2_INSTANCE_IDS[@]}" --query 'Reservations[*].Instances[*].[KeyName,SecurityGroups[0].GroupId]' --region "$AWS_REGION" | jq '.')
  echo "STEPS_COMPLETED[get-resources]=true" | sudo tee --append "$PROGRESS_FILE" >> /dev/null
}

# Delete the resources that are used only by the recently terminated EC2 instances
function deleteEc2Resources() {
  gatherResourcesToDelete
  deleteClusterKeyPairsNotInUse
  deleteClusterSecurityGroupsNotInUse
}

# Extract the resources which should be deleted from the EC2_RESOURCES JSON variable
function gatherResourcesToDelete() {
  INSTANCE_COUNT="${#EC2_INSTANCE_IDS[@]}"
  KEY_PAIRS_TO_DELETE=()
  SECURITY_GROUPS_TO_DELETE=()
  for (( INSTANCE_INDEX=0; INSTANCE_INDEX<INSTANCE_COUNT; INSTANCE_INDEX++ )); do
    KEY_PAIRS_TO_DELETE+=($(sed -e 's/^"//' -e 's/"$//' <<< $(echo "$EC2_RESOURCES" | jq '.['"$INSTANCE_INDEX"'][0][0]')))
    SECURITY_GROUPS_TO_DELETE+=($(sed -e 's/^"//' -e 's/"$//' <<< $(echo "$EC2_RESOURCES" | jq '.['"$INSTANCE_INDEX"'][0][1]')))
  done
}

# Delete all key pairs that were (1) used by the instances in the cluster and (2) are not still in use
function deleteClusterKeyPairsNotInUse() {
  for KEY_PAIR in "${KEY_PAIRS_TO_DELETE[@]}"; do
    KEY_PAIR_STILL_IN_USE=false
    KEY_PAIR_USE=$(aws ec2 describe-instances --filters "Name=instance-state-name,Values=running,Name=key-name,Values="$KEY_PAIR"" --query 'Reservations[*].Instances[*]' --region "$AWS_REGION" | jq '.[0]')
    KEY_PAIR_USE_COUNT=$(echo "$KEY_PAIR_USE" | jq '. | length')
    for (( KEY_PAIR_USE_INDEX=0; KEY_PAIR_USE_INDEX<KEY_PAIR_USE_COUNT; KEY_PAIR_USE_INDEX++ )); do
      THIS_KEY_PAIR_USE_STATE=$(echo "$KEY_PAIR_USE" | jq '.['"$KEY_PAIR_USE_INDEX"'].State.Name')
      if [ ! "$THIS_KEY_PAIR_USE_STATE" == "\"terminated\"" ]; then
        KEY_PAIR_STILL_IN_USE=true
        break
      fi
    done
    if [ $KEY_PAIR_STILL_IN_USE == false ]; then
      aws ec2 delete-key-pair --key-name "$KEY_PAIR" --region "$AWS_REGION"
    fi
  done
  echo "STEPS_COMPLETED[delete-key-pairs]=true" | sudo tee --append "$PROGRESS_FILE" >> /dev/null
}

# Delete all security groups that were (1) used by the instances in the cluster and (2) are not still in use
function deleteClusterSecurityGroupsNotInUse() {
  for SECURITY_GROUP in "${SECURITY_GROUPS_TO_DELETE[@]}"; do
    SECURITY_GROUP_STILL_IN_USE=false
    SECURITY_GROUP_USE=$(aws ec2 describe-instances --filters "Name=instance-state-name,Values=running,Name=instance.group-id,Values="$SECURITY_GROUP"" --query 'Reservations[*].Instances[*]' --region "$AWS_REGION" | jq '.[0]')
    SECURITY_GROUP_USE_COUNT=$(echo "$SECURITY_GROUP_USE" | jq '. | length')
    for (( SECURITY_GROUP_USE_INDEX=0; SECURITY_GROUP_USE_INDEX<SECURITY_GROUP_USE_COUNT; SECURITY_GROUP_USE_INDEX++ )); do
      THIS_SECURITY_GROUP_USE_STATE=$(echo "$SECURITY_GROUP_USE" | jq '.['"$SECURITY_GROUP_USE_INDEX"'].State.Name')
      if [ ! "$THIS_SECURITY_GROUP_USE_STATE" == "\"terminated\"" ]; then
        SECURITY_GROUP_STILL_IN_USE=true
        break
      fi
    done
    if [ $SECURITY_GROUP_STILL_IN_USE == false ]; then
      aws ec2 delete-security-group --group-id "$SECURITY_GROUP" --region "$AWS_REGION"
    fi
  done
  echo "STEPS_COMPLETED[delete-security-groups]=true" | sudo tee --append "$PROGRESS_FILE" >> /dev/null
}

# Create the configuration variable needed for the monitorProgress.sh script
function defineExpectedProgress() {
EXPECTED_PROGRESS=$(cat <<-EOF
[
  {
    "goal": "Taking Stock of Resources in Cluster",
    "steps": [
      {
        "label": "Getting EC2 instance IDs in the cluster",
        "variable": "get-instance-ids"
      },
      {
        "label": "Getting key pairs and security groups in the cluster",
        "variable": "get-resources"
      }
    ]
  },
  {
    "goal": "Terminating EC2 Instances",
    "steps": [
      {
        "label": "Send order to terminate all instances in cluster",
        "variable": "send-terminate-order"
      },
      {
        "label": "Waiting for instances to terminate",
        "variable": "wait-for-termination"
      }
    ]
  },
  {
    "goal": "Deleting Other EC2 Resources",
    "steps": [
      {
        "label": "Deleting key pairs from the cluster that are no longer in use",
        "variable": "delete-key-pairs"
      },
      {
        "label": "Deleting security groups from the cluster that are no longer in use",
        "variable": "delete-security-groups"
      }
    ]
  },
  {
    "goal": "Deleting Cluster",
    "steps": [
      {
        "label": "Deleting cluster",
        "variable": "delete-cluster"
      }
    ]
  }
]
EOF
)
}

defineColorPalette
handleInput "$@"
startMonitoringProgress
getEc2ResourcesInCluster
terminateEc2Instances
deleteEc2Resources
deleteEcsCluster
stopMonitoringProgress
