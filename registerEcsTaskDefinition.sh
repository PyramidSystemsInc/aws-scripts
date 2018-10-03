#! /bin/bash

# Break Docker run statement into individual variables
function parseAllDockerRunCommands() {
  for CONTAINER in "${CONTAINERS[@]}"; do
    parseDockerRunCommand $CONTAINER
  done
}

function parseDockerRunCommand() {
  ARGS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name) NAME+=("$2"); shift 2;;
      --cpu) CPU+=($(($2 * $CPU_COEF))); shift 2;;
      --memory) MEM=$(echo "scale=0; (($2 * $MEMORY_COEF) / 1)" | bc); MEMORY+=("$MEM"); shift 2;;
      docker) shift 1;;
      run) shift 1;;
      -*) echo "unknown option: $1" >&2; exit 1;;
      *) ARGS+=("$1"); shift 1;;
    esac
  done
  for ARG in "${ARGS[@]}"; do
    if [ -n "$ARG" ]; then
      IMAGE+=("$ARG")
    fi
  done
}

function createTaskDefinitionJson() {
	TASK_DEFINITION=$(cat <<-EOF
		{
		  "family": "$TASK_NAME",
		  "containerDefinitions": [
	EOF
  )
  CONTAINER_COUNT="${#CONTAINERS[@]}"
  for (( CONTAINER_INDEX=0; CONTAINER_INDEX<CONTAINER_COUNT; CONTAINER_INDEX++ )); do
    THIS_NAME="${NAME[$CONTAINER_INDEX]}"
    THIS_IMAGE="${IMAGE[$CONTAINER_INDEX]}"
    THIS_CPU="$${CPU[$CONTAINER_INDEX]}"
    THIS_MEMORY="${MEMORY[$CONTAINER_INDEX]}"
    if [ $CONTAINER_INDEX -eq 0 ]; then
			TASK_DEFINITION="$TASK_DEFINITION"$(cat <<-EOF

				    {
				      "name": "$THIS_NAME",
				      "image": "$THIS_IMAGE",
				      "cpu": $THIS_CPU,
				      "memory": $THIS_MEMORY,
				      "essential": true

			EOF
			)
    else
			TASK_DEFINITION="$TASK_DEFINITION"$(cat <<-EOF

				    },
				    {
				      "name": "$THIS_NAME",
				      "image": "$THIS_IMAGE",
				      "cpu": $THIS_CPU,
				      "memory": $THIS_MEMORY,
				      "essential": true

			EOF
			)
    fi
  done
	TASK_DEFINITION="$TASK_DEFINITION"$(cat <<-EOF

		    }
		  ]
		}
	EOF
  )
  echo "$TASK_DEFINITION"
}

function registerTaskDefinition() {
  aws ecs register-task-definition --cli-input-json "$TASK_DEFINITION" >> /dev/null
}

function buildContainersArray() {
  CONTAINERS=()
  RAW_CONTAINER_DATA=($1)
  CONTAINER=""
  for TERM in "${RAW_CONTAINER_DATA[@]}"; do
    if [ "$TERM" == "docker" ]; then
      CONTAINERS+=("$CONTAINER")
      CONTAINER="$TERM"
    else
      CONTAINER="$CONTAINER"" $TERM"
    fi
  done
  CONTAINERS+=("$CONTAINER")
  unset 'CONTAINERS[0]'
}

AWS_REGION='us-east-2'
CPU_COEF=1024
MEMORY_COEF=995
TASK_NAME="$2"
CLUSTER_NAME="$3"
buildContainersArray "$1"
parseAllDockerRunCommands "${CONTAINERS[@]}"
#createTaskDefinitionJson
#registerTaskDefinition

declare -A AWS_T3_INSTANCE_SPEC0=(
  [name]='t3.nano'
  [cpu]=2048
  [memory]=497
)
declare -A AWS_T3_INSTANCE_SPEC1=(
  [name]='t3.micro'
  [cpu]=2048
  [memory]=995
)
declare -A AWS_T3_INSTANCE_SPEC2=(
  [name]='t3.small'
  [cpu]=2048
  [memory]=1990
)
declare -A AWS_T3_INSTANCE_SPEC3=(
  [name]='t3.medium'
  [cpu]=2048
  [memory]=3980
)
declare -A AWS_T3_INSTANCE_SPEC4=(
  [name]='t3.large'
  [cpu]=2048
  [memory]=7960
)
declare -A AWS_T3_INSTANCE_SPEC5=(
  [name]='t3.xlarge'
  [cpu]=4096
  [memory]=15920
)
declare -A AWS_T3_INSTANCE_SPEC6=(
  [name]='t3.2xlarge'
  [cpu]=8192
  [memory]=31840
)
declare -n AWS_T3_INSTANCE_SPEC

#for AWS_T3_INSTANCE_SPEC in ${!AWS_T3_INSTANCE_SPEC@}; do
#  echo ${AWS_T3_INSTANCE_SPEC[name]}
#  echo ${AWS_T3_INSTANCE_SPEC[cpu]}
#  echo ${AWS_T3_INSTANCE_SPEC[memory]}
#  echo -e ""
#done

CPU_REQUIREMENT=0
for CPU_VALUE in "${CPU[@]}"; do
  CPU_REQUIREMENT=$(($CPU_REQUIREMENT + $CPU_VALUE))
done
MEMORY_REQUIREMENT=0
for MEMORY_VALUE in "${MEMORY[@]}"; do
  MEMORY_REQUIREMENT=$(($MEMORY_REQUIREMENT + $MEMORY_VALUE))
done

# 1a. Check if any current instance can handle the requirement
#   If so, continue
#   If not, find the minimum t3 size instance that would handle the requirement

CONTAINER_INSTANCE_ARNS=$(aws ecs list-container-instances --cluster "$CLUSTER_NAME" --region "$AWS_REGION" | jq '.containerInstanceArns')
INSTANCE_COUNT=$(echo $CONTAINER_INSTANCE_ARNS | jq '. | length')
for (( INSTANCE_INDEX=0; INSTANCE_INDEX<INSTANCE_COUNT; INSTANCE_INDEX++ )); do
  THIS_INSTANCE_ARN=$(echo "$CONTAINER_INSTANCE_ARNS" | jq '.['"$INSTANCE_INDEX"']')
  echo "$CLUSTER_NAME"
  echo "$THIS_INSTANCE_ARN"
  echo "$AWS_REGION"
  #aws ecs describe-container-instances --cluster "$CLUSTER_NAME" --container-instances "$THIS_INSTANCE_ARN" --region "$AWS_REGION"
done
