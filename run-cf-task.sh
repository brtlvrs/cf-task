#!/bin/bash
debug=false
workdir="/brtlvrs"
host_repo_root="~/cf-task-project/repo"
repo_root_name="repo"

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

    -h | --help             this message
    -t | --task <path>      full path to concourse task.yml
    -r | --repo_root <path> path to root folder for config repo
    -n | --repo_name <var>  name of config repo root folder in container
    -d | --debug        show debug messages
EOF
}

function debug() {
    # send debug message to STDERR
    [[ $debug == true ]] && echo "DBG: $@" >&2
}

function _parse_options() {
    # parse script arguments
    local option
    local options=()

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

        ((i++))
    }
    # handle arguments
    for (( i=0 ; i< ${#options[@]}; i++)) do
        option="${options[i]}"
        case ${option} in
            -d | --debug ) # set debug variable to true
                debug=false
                show_docker=true
            ;;
            -dd )
                show_docker=true
                debug=true
            ;;
            -h | --help ) # show help message
                _usage
                exit 0
            ;;
            -t | --task ) # path to concourse task file
                validate_value
                _parse_task "${options[i]}"
                ;;
            -r | --repo_root ) # path to repo
                validate_value
                host_repo_root="${options[i]}"
                debug "host_repo_root: $host_repo_root"
                ;;
            -n | --repo_name ) 
                validate_value
                repo_root_name="${options[i]}"
                debug "repo_root_name: $repo_root_name"
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

    task_yml="$1"
    debug "Processing Concourse task file $task_yml"

    # GUARDRAIL Check if the task.yml file exists
    if [ ! -f "$task_yml" ]; then
        echo "Error: Task YAML file '$task_yml' not found"
        exit 1
    fi

    # GUARDRAIL check if yq is installed
    if ! command -v yq &>/dev/null; then
        echo "yq is not installed, cannot parse $task_yml"
        exit 1
    fi

    # GUARDRAIL check image_resource type
    if [[ $(yq e '.image_resource.type' "$task_yml") != "registry-image" ]]; then
        echo "image_resoure type defined in $task_yml is not 'registry-image'"
        exit 1
    fi

    # Parse task.yml for Docker image and script path
    debug "image resource type: $(yq -e '.image_resource.type' $task_yml)"

    docker_image=$(yq e '.image_resource.source.repository + ":" + .image_resource.source.tag' "$task_yml")
    debug "docker_image: $docker_image "
    script_path=$(yq e '.run.path' "$task_yml")
    debug "script_path: $script_path"

    # Create an array to store input and output mount points
    input_mounts=()
    output_mounts=()

    # Parse task.yml for inputs and outputs and create mount points
    inputs=$(yq e '.inputs[].name' "$task_yml")
    outputs=$(yq e '.outputs[].name' "$task_yml")

    for ((i=0 ; i < ${#inputs[@]}; i++)) do
        local input="${inputs[i]}"

        # check if input is a config repo
        if [[ "$input"  == "$repo_root_name" ]]; then
            echo "Found repo in inputs."
            input_mounts+=("-v $host_repo_root:$repo_root_name")
            continue
        fi

        local mount=$PWD/$input:$workdir/$input
        debug "mount: $mount"
        input_mounts+=("-v $mount")
    done

    debug "input_mounts: ${input_mounts[@]}"

    for output in $outputs; do
        output_mounts+=("-v $PWD/$output:/$output")
    done
    debug "output_mounts: ${output_mounts[@]}"

}

_show_docker_params() {

    cat <<EOF

    Docker run parameters

    --rm
    -it
    --workdir   $workdir
    ${input_mounts[@]}
    ${output_mounts[@]}
    image       $docker_image

EOF
}

##MAIN
_header
_parse_options "$@"

# show docker parameters
[[ $show_docker == "true" ]] && _show_docker_params

# Run the Docker container with environment variables, symbolic link, and interactive shell
docker run --rm -it \
    "${input_mounts[@]}" \
    "${output_mounts[@]}" \
    -e "$env_vars" \
    -w $workdir \
    "$docker_image" \
    /bin/bash -c "ln -s $script_path /work/task && /bin/bash"