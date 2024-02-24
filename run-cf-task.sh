#!/bin/bash
debug=false
workdir="/brtlvrs"

function _header() {

    cat <<EOF

=====================================================
         ____  ____ _____ _ __     ______  ____  
        | __ )|  _ \_   _| |\ \   / /  _ \/ ___| 
        |  _ \| |_) || | | | \ \ / /| |_) \___ \ 
        | |_) |  _ < | | | |__\ V / |  _ < ___) |
        |____/|_| \_\|_| |_____\_/  |_| \_\____/ 

        Ephemeral runtime for Concourse task

=====================================================

EOF
}

function _usage() {
    cat <<EOF

    This is a random help message to be displayed

    options:

    -h | --help         this message
    -t | --task <path>  full path to concourse task.yml
    -r | --repo <path>  path to root folder for config repo
    -d | --debug        show debug messages
EOF
}

function debug() {
    [[ $debug == true ]] && echo "DBG: $@" >&2
}

function _parse_options() {
    # parse script arguments
    local option
    local options=()
    debug=true

    # guardrail: are there any arguments ?
    if [[ $# -eq 0 ]]; then
        return
    fi

    # Move all arguments into an array
    while [[ $# -gt 0 ]]; do
        options+=("$1")
        shift
    done

    # Loop through the array and split items when it is a key=value format
    for option in "${options[@]}"; do
        # Check if the argument contains "=" character
        if [[ "$option" == *=* ]]; then
            # Split the argument and insert separate parts into the array
            IFS='=' read -ra parts <<< "$option"
            options+=("${parts[@]}")
        fi
    done

    function validate_value() {
        # validate the next item in the options array 
        
        if [[ $i -eq $(( ${#options[@]} - 1 ))  ]]; then
            ## argument was the last argument set, not followed with a value
            echo "Option $option has no value set"
            exit 1
        fi

        local next_value=${options[$(( $i + 1))]}
        if [[  "$next_value" =~ ^- ]]; then
            echo "Expected value for option $option but got option $next_value"
            exit 1
        fi
    }
    # handle arguments
    for (( i=0 ; i< ${#options[@]}; i++)) do
        option="${options[i]}"
        case ${option} in
            -d | --debug ) # set debug variable to true
                debug=true
            ;;
            -h | --help ) # show help message
                _usage
                exit 0
            ;;
            -t | --task ) # path to concourse task file
                validate_value
                _parse_task "${options[i + 1]}"
                ((i++)) # skip nexzt item in the array, it is not an option
                ;;
            -r | --repo ) # path to repo
                validate_value
                host_repo_folder="${options[i + 1]}"
                ((i++)) # skip nexzt item in the array, it is not an option
                ;;
            *)
                echo "unknown script option $option"
                exit 1
            ;;
        esac
    done

}


function _parse_task()
{
    debug=true
    # Check if the task.yml file is provided as argument
    if [ $# -ne 1 ]; then
        echo "Usage: $0 <task.yml>"
        exit 1
    fi

    task_yml="$1"

    # Check if the task.yml file exists
    if [ ! -f "$task_yml" ]; then
        echo "Error: Task YAML file '$task_yml' not found"
        exit 1
    fi

    # Parse task.yml for Docker image and script path
    docker_image=$(yq e '.image_resource.source.repository + ":" + .image_resource.source.tag' "$task_yml")
    script_path=$(yq e '.run.path' "$task_yml")

    # Create an array to store input and output mount points
    input_mounts=()
    output_mounts=()

    # Parse task.yml for inputs and outputs and create mount points
    inputs=$(yq e '.inputs[].name' "$task_yml")
    outputs=$(yq e '.outputs[].name' "$task_yml")

    for input in $inputs; do
        input_mounts+=("-v $PWD/$input:/$input")
    done

    for output in $outputs; do
        output_mounts+=("-v $PWD/$output:/$output")
    done

    # Run the Docker container with environment variables, symbolic link, and interactive shell
    docker run --rm -it \
        "${input_mounts[@]}" \
        "${output_mounts[@]}" \
        -e "$env_vars" \
        -w $workdir \
        "$docker_image" \
        /bin/bash -c "ln -s $script_path /work/task && /bin/bash"

}

##MAIN
_header
_parse_options "$@"
debug "host_repo_folder: $host_repo_folder"