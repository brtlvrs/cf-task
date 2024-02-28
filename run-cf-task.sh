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
                task_file="${options[i]}"
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


function _parse_task_file()
{
    debug=true

    function parse_image_resource() {
        echo "  - parsing .image_resource for docker image"
        local image_version=$(yq e '.image_resource.source.tag' $task_yml) || "latest"
        local image_repo=$(yq e '.image_resource.source.repository' "$task_yml") || ${echo "Couldn't find property .image_resource.source.repository."&& exit 1}
        docker_image="$image_repo:$image_version"
        debug "docker_image: $docker_image "
    }

    function parse_inputs() {
        echo "  - parsing .inputs for docker -v mount options"
        inputs=$(yq e '.inputs[].name' "$task_yml")
        IFS=$'\n' read -r -d ' ' -a input_mounts <<< "$inputs"

        # process found names in .inputs
        for ((i=0 ; i < ${#input_mounts[@]}; i++)) do
            local input="${input_mounts[i]}"

            # check if input is the config repo
            if [[ "$input"  == "$repo_root_name" ]]; then
                echo "Found config repo in inputs."
                host_repo_root="${host_repo_root/#\~/$HOME}"
                mounts+=("-v $host_repo_root:$repo_root_name")
                continue
            fi

            # input is not the config repo
            local mount=$PWD/$input:$workdir/$input
            mounts+=("-v $mount")
        done
    }

    task_yml=$(readlink -f "$1")
    echo "Processing Concourse task file $task_yml"

    if [ -z $task_yml ]; then
        debug "Skipping taskfile parsing."
        return 0
    fi

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

    # GUARDRAIL check for image_resource type == registry-image
    if [[ $(yq e '.image_resource.type' "$task_yml") != "registry-image" ]]; then
        echo "image_resoure type defined in $task_yml is not 'registry-image'"
        exit 1
    fi
    debug "image resource type: $(yq -e '.image_resource.type' $task_yml)"

    # parsing .image_resource properties to set docker_image
    if [[ $(yq e ' has("image_resource")' "$task_yml") != "true" ]]; then
        echo "   .image_resource not found"
        exit 1
    fi
    parse_image_resource


    # parsing .run.path
    yq e '.run | has(".path")' "$task_yml")
    if [[ $(yq e '.run | has(".path")' "$task_yml") != "true" ]]; then
        echo "    .run.path not found"
        exit 1
    fi
    echo "  - parsing .run.path for task alias to create"
    script_path=$(yq e '.run.path' "$task_yml")
    debug "script_path: $script_path"

    # Parse .inputs
    if [[ $(yq e 'has(".inputs")' "$task_yml") != "true" ]]; then
        echo "    .inputs not found"
        exit 1
    fi
    parse_inputs

    # parsing .outputs
    echo "  - parsing .outputs for docker -v mount options"
    outputs=$(yq e '.outputs[].name' "$task_yml")
    IFS=$'\n' read -r -d ' ' -a output_mounts <<< "$outputs"

    # process found names in .outputs
    for ((i=0 ; i < ${#output_mounts[@]}; i++)) do
        local output="${output_mounts[i]}"

        local mount=$PWD/$output:$workdir/$output
        mounts+=("-v $mount")
    done

    # parse .params
    # query only the keys under .params
    echo "  - parsing .params for docker -e options"
    local list=$(yq e '.params | keys' "$task_yml")
    for item in $list; do
        [[ $item == "-" ]] && continue # skip the dash
        env_vars+=("-e $item")
    done
}

_show_docker_params() {

    cat <<EOF

    Docker run parameters

    --rm
    -it
    --workdir   $workdir
    ${mounts[@]}
    ${env_vars[@]}
    image       $docker_image

EOF
}

##MAIN
mounts=()
env_vars=()
_header
_parse_options "$@"
_parse_task_file "$task_file"

# show docker parameters
[[ $show_docker == "true" ]] && _show_docker_params

# Run the Docker container with environment variables, symbolic link, and interactive shell
docker run --rm -it \
    "${mounts[@]}" \
    -e "$env_vars" \
    -w $workdir \
    "$docker_image" \
    /bin/bash -c "ln -s $script_path /work/task && /bin/bash"