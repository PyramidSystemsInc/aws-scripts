#! /bin/bash

# Break Docker run statement into individual variables
function handleInput() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name) NAME="$2"; shift 2;;
      --cpu) CPU="$2"; shift 2;;
      --memory) MEMORY="$2"; shift 2;;
      docker) shift 1;;
      run) shift 1;;
      -*) echo "unknown option: $1" >&2; exit 1;;
      *) ARGS+=("$1 "); shift 1;;
    esac
  done
  for ARG in "${ARGS[@]}"; do
    if [ -n "$ARG" ]; then
      IMAGE="$ARG"
    fi
  done
}

function createTaskDefinitionJson() {
}

handleInput $1
createTaskDefinitionJson

echo Name = "$NAME"
echo Image = "$IMAGE"
echo CPU = "$CPU"
echo MEMORY = "$MEMORY"
