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
      --cpu) CPU+=("$2"); shift 2;;
      --memory) MEMORY+=("$2"); shift 2;;
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
		TASK_DEFINITION="$TASK_DEFINITION"$(cat <<-EOF
	
			    {
			      "name": "${NAME[$CONTAINER_INDEX]}",
			      "image": "${IMAGE[$CONTAINER_INDEX]}",
			      "cpu": 1024,
			      "memory": 995,
			      "essential": true
			    },
	
		EOF
		)
  done
	TASK_DEFINITION="$TASK_DEFINITION"$(cat <<-EOF

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

TASK_NAME="$2"
buildContainersArray "$1"
parseAllDockerRunCommands "${CONTAINERS[@]}"
createTaskDefinitionJson
#registerTaskDefinition
