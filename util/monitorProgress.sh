#! /bin/bash

# Clean up the configuration progress file
function cleanup() {
  if [ -f /configurationProgress.sh ]; then
    sudo rm /configurationProgress.sh
  fi
}

# Define all colors used for output
function defineColorPalette() {
  COLOR_RED_BOLD='\033[1;91m'
  COLOR_GREEN_BOLD='\033[1;32m'
  COLOR_BLUE_BOLD='\033[1;34m'
  COLOR_WHITE_BOLD='\033[1;97m'
  COLOR_NONE='\033[0m'
}

# Define special characters
function defineSpecialCharacters() {
  CHECK_MARK='\xE2\x9C\x94'
}

# Create a configuration progress file in case it does not already exist
function ensureConfigurationProgressFile() {
  if [ -f /configurationProgress.sh ]; then
    sudo rm /configurationProgress.sh
  fi
  sudo touch /configurationProgress.sh
  sudo chmod 755 /configurationProgress.sh
}

# Show readable output based on input JSON
function monitorProgress() {
  echo -e ""
  ELLIPSIS=""
  for (( LINE_INDEX=0; LINE_INDEX<STEP_COUNT; LINE_INDEX++ )) do
    echo -e ""
  done
  while : ; do
    . /configurationProgress.sh
    ELLIPSIS+="."
    echo -en "\e[${STEP_COUNT}A"
    if [ ${#STEPS_COMPLETED[@]} -eq $SUB_STEP_COUNT ]; then
      ALL_STEPS_SUCCESSFUL=true
      for (( STEP_COMPLETED_INDEX=1; STEP_COMPLETED_INDEX<STEP_COUNT; STEP_COMPLETED_INDEX++ )) do
        if [ ${STEPS_COMPLETED[$STEP_COMPLETED_INDEX]} != "true" ]; then
          ALL_STEPS_SUCCESSFUL=false
        fi
      done
      if [ "$ALL_STEPS_SUCCESSFUL" == "true" ]; then
        echo -e "${COLOR_GREEN_BOLD}[ ${CHECK_MARK} DONE ]${COLOR_WHITE_BOLD} $JOB_LABEL          "
      else
        echo -e "${COLOR_RED_BOLD}[ SKIPPED ]${COLOR_WHITE_BOLD} $JOB_LABEL           "
      fi
    else
      if [ ${#ELLIPSIS} -gt 3 ]; then
        echo -e "${COLOR_BLUE_BOLD}[ IN PROGRESS ]${COLOR_WHITE_BOLD} $JOB_LABEL   "
        ELLIPSIS=""
      else
        echo -e "${COLOR_BLUE_BOLD}[ IN PROGRESS ]${COLOR_WHITE_BOLD} $JOB_LABEL$ELLIPSIS"
      fi
    fi
    INDEX=1
    for STEP_LABEL in "${STEP_LABELS[@]}"; do
      echo -e "    ${COLOR_NONE}- [$([ -n "${STEPS_COMPLETED["$INDEX"]}" ] && "${STEPS_COMPLETED["$INDEX"]}" == "true" && echo "X" || echo " ")] "$STEP_LABEL""
      ((INDEX++))
    done
    sleep 0.75
    if [ ${#STEPS_COMPLETED[@]} -eq $SUB_STEP_COUNT ]; then
      break
    fi
  done
}

function readExpectedProgressInput() {
  RAW_STEPS=$1
  JOB_LABEL=$(sed -e 's/^"//' -e 's/"$//' <<< $(echo "$RAW_STEPS" | jq '.[0]'))
  STEP_LABELS=()
  STEP_COUNT=$(echo "$RAW_STEPS" | jq '. | length')
  SUB_STEP_COUNT=$(($STEP_COUNT - 1))
  for (( STEP_INDEX=1; STEP_INDEX<STEP_COUNT; STEP_INDEX++ )) do
    STEP_LABELS+=("$(sed -e 's/^"//' -e 's/"$//' <<< $(echo "$RAW_STEPS" | jq '.['"$STEP_INDEX"']'))")
  done
}

ensureConfigurationProgressFile
readExpectedProgressInput "$@"
defineColorPalette
defineSpecialCharacters
monitorProgress
cleanup
