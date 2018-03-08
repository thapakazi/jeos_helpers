#!/bin/bash

export EC2_SELF_METAS='/tmp/ec2-selfmeta'
export CUSTOM_TAGS_FILE='/tmp/.custom_tags'
export EC2_TAGS_FILE_ALL='/tmp/ec2-tags'
export INSTNANCE_COUNTER_VALUE='/tmp/.ec2_instance_counter'
    
jeos_generate_ec2metadata(){
    until ec2metadata > ${EC2_SELF_METAS}; do :; done
}

jeos_get_meta(){
    meta_of="${1:-instance-id}"
    [ -f ${EC2_SELF_METAS} ] || jeos_generate_ec2metadata
    [ -f ${EC2_SELF_METAS} ] && awk  -F': ' /${meta_of}/'{print $2}' ${EC2_SELF_METAS}
}

jeos_get_instance_region(){
    curl -s http://169.254.169.254/latest/dynamic/instance-identity/document| awk -F\" '/region/{print $4}'
}

jeos_populate_ec2_tags_raw(){
    # getting values if they are blank still
    [ -z "${REGION}" ] && REGION=${jeos_get_instance_region:-us-west-1}
    [ -z "${INSTANCE_ID}" ] && INSTANCE_ID=$(jeos_get_meta "instance-id")

    until aws ec2 describe-tags --filters \
              "Name=resource-id,Values=$INSTANCE_ID" \
              --region=$REGION --output=text > ${EC2_TAGS_FILE_ALL}; do :; done
    
}

# EXTENSION: write a usage function 
jeos_get_value_for_tag(){
    [ -f "${EC2_TAGS_FILE_ALL}" ] || jeos_populate_ec2_tags_raw
    tag=${1:-queues}
    awk -v t_for_tag=$tag '$2 == t_for_tag {print $NF}' "${EC2_TAGS_FILE_ALL}"
}

jeos_tags_to_env(){
    export QUEUES=$(jeos_get_value_for_tag  "queues")
    export ROLE=$(jeos_get_value_for_tag "role")
    export ENV=$(jeos_get_value_for_tag "env")
    export PROJECT=$(jeos_get_value_for_tag "project")
    export NAME=$(jeos_get_value_for_tag "Name")

    export INSTANCE_ID=$(jeos_get_meta "instance-id")
    export LOCAL_IPV4=$(jeos_get_meta "local-ipv4")
    export PUBLIC_HOSTNAME=$(jeos_get_meta "public-hostname")
    export REGION=$(jeos_get_instance_region)
    export ZONE=${REGION}.ec2.jeos.internal

}

jeos_tags_to_env_refresh(){
    rm ${EC2_TAGS_FILE_ALL} && jeos_tags_to_env
}

utils_check_if_user_is_root(){
    if [ "$(id -u)" != "0" ]; then
        echo "This script must be run as root" 1>&2
        exit 1
    fi
}

utils_generate_random_number(){
    INSTANCE_RANDOM_RANGE=1000
    INSTANCE_RANDOM_BASE=100

    RANDOM_NUM=$(( ( RANDOM % INSTANCE_RANDOM_RANGE )  + INSTANCE_RANDOM_BASE ))
    echo ${RANDOM_NUM}
}

# this one uses the cache, if random number is alrady generated.
utils_get_random_number(){
    utils_check_if_user_is_root
    [ -f "${INSTNANCE_COUNTER_VALUE}" ] && cat ${INSTNANCE_COUNTER_VALUE} && return 0
    utils_generate_random_number | tee ${INSTNANCE_COUNTER_VALUE}
}

jeos_get_all_tags_with_dynamic_Name(){
    # random instance index
    export NEXT_COUNT=$(utils_get_random_number)
    jeos_tags_to_env
    export NAME=${ROLE}${NEXT_COUNT}${NAME_TAIL_STRING}
}

jeos_save_to_etc_environment(){
    SYSMTEM_WIDE_ENVIRONMENT_FILE=/etc/environment
    SYSMTEM_WIDE_ENVIRONMENT_BACKUP_FILE="/etc/environment_$(date +%Y-%m-%d-%H-%M-%S)"

    echo "saving old envs to  $SYSMTEM_WIDE_ENVIRONMENT_BACKUP_FILE, if you need it later"
    mv ${SYSMTEM_WIDE_ENVIRONMENT_FILE} $SYSMTEM_WIDE_ENVIRONMENT_BACKUP_FILE && :> $SYSMTEM_WIDE_ENVIRONMENT_FILE
    echo "PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games'" | tee ${SYSMTEM_WIDE_ENVIRONMENT_FILE}
    echo "LC_ALL=en_US.UTF-8" | tee -a ${SYSMTEM_WIDE_ENVIRONMENT_FILE}
    echo "LANG=en_US.UTF-8" | tee -a ${SYSMTEM_WIDE_ENVIRONMENT_FILE}

    echo "RAILS_ENV=$(jeos_get_value_for_tag 'env')"| tee -a ${SYSMTEM_WIDE_ENVIRONMENT_FILE}
    echo "RACK_ENV=$(jeos_get_value_for_tag 'env')"| tee -a ${SYSMTEM_WIDE_ENVIRONMENT_FILE}

    jeos_tags_to_env
    echo "MACHINE_NAME=${NAME}"| tee -a ${SYSMTEM_WIDE_ENVIRONMENT_FILE}
    echo "ROLE=${ROLE}"| tee -a ${SYSMTEM_WIDE_ENVIRONMENT_FILE}
    echo "ENV=${ENV}"| tee -a ${SYSMTEM_WIDE_ENVIRONMENT_FILE}
    echo "PROJECT=${PROJECT}"| tee -a ${SYSMTEM_WIDE_ENVIRONMENT_FILE}
    [ -z "${QUEUES}" ] || echo "queues=${QUEUES}"| tee -a ${SYSMTEM_WIDE_ENVIRONMENT_FILE} 
}

utils_check_if_dynamic_tags_set_True(){
    jeos_populate_ec2_tags_raw
    dynamic_tags=$(jeos_get_value_for_tag "dynamic_tags")
    [ ! -z "$dynamic_tags" -a "$dynamic_tags" = "True" ] && return 0
    return 1
}

# this is where we export our basic (generic) env variables like HOME, PATH...
utils_export_basic_env(){
    [ "$(/usr/bin/id -u)" = "0" ] && export HOME=/root || export HOME="/home/$(whoami)"
    # please add more
}


# get number based on parent's dir name
# if convention is violated while making ~/service/xyz dir name
# ...PID of this script is appended as file-name :)
utils_get_parent_dir_num(){
    RUNDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    NUM=$(basename ${RUNDIR} | sed 's/\([a-zA-Z_-]*\)-\([0-9]*\)$/\2/')

    # check if num: http://stackoverflow.com/a/806923/2636474
    re_num='^[0-9]+$'
    if ! [[ $NUM =~ $re_num ]] ; then
        NUM=$$
    fi
    echo $NUM
}

