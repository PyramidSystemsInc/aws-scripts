#! /bin/bash

# Create ECS cluster
function createCluster() {
  aws ecs create-cluster --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" >> /dev/null
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
	EXPECTED_PROGRESS=$(cat <<-EOF
		[
		  "Creating ECS Cluster",
		  "Creating ECS Cluster"
		]
	EOF
	)
}

# Handle user input
function handleInput() {
  AWS_REGION="us-east-2"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      # Required inputs
      --name) CLUSTER_NAME=$2; shift 2;;
      --region) AWS_REGION="$2"; shift 2;;
      # Optional inputs yet to be implemented
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

handleInput "$@"
defineColorPalette
defineExpectedProgress
trap 'kill $MONITOR_PROGRESS_PID; exit' SIGINT; ./monitorProgress.sh "$EXPECTED_PROGRESS" & MONITOR_PROGRESS_PID=$!
createCluster
sleep 3; if pgrep $MONITOR_PROGRESS_PID; then pkill $MONITOR_PROGRESS_PID; fi
echo -e ""
