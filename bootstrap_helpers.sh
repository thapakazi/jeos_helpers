self_init(){
    # if some how, we forgot to set these vars, failsafe with defautls
    export USERDATA_TMPDIR=${USERDATA_TMPDIR:-/tmp/userdata}
    export ANSIBLE_DEBUG_FLAG=${ANSIBLE_DEBUG_FLAG:-'-vvvv'}
    export CUSTOM_ANSIBLE_ROLES_PATH="$USERDATA_TMPDIR/ansible-roles"
} && self_init

# Name: this function's sole purpose is to pull ssh key for user
# Usage:
#   $ su - user -c ' utils_pull_private_key '
#   like: export PRIVATE_KEY_PATH_IN_S3=mybucketname/path/to/my/private_key && su - user -c 'utils_pull_private_key'
#      if your key is in other bucket and other path
utils_pull_private_key (){
    [ -f $USERDATA_TMPDIR/.secrets ] && source $USERDATA_TMPDIR/.secrets # source secrets if they are available
    SSH_DIR="$HOME/.ssh" && mkdir -p $SSH_DIR
    PRIVATE_KEY_IN_LOCAL="${SSH_DIR}/id_rsa"

    BUCKET_REGION="${BUCKET_REGION:-default-region}"
    PRIVATE_KEY_PATH_IN_S3="${PRIVATE_KEY_PATH_IN_S3:-my_s3bucket/autoscaling/id_rsa}"

    # asuming awscli is already in JEOS
    aws s3 cp s3://${PRIVATE_KEY_PATH_IN_S3} ${PRIVATE_KEY_IN_LOCAL} --region ${BUCKET_REGION}
    chmod 400 ${PRIVATE_KEY_IN_LOCAL}

    # if you reached this far
    echo "#SECURITY :: PLEASE CLEAN UP THE FILE $PRIVATE_KEY_IN_LOCAL"
    echo "#SECURITY :: rm -rf $PRIVATE_KEY_IN_LOCAL"
}

utils_clone_deployment_roles() {

    ## Improve me later please...!
    [ -z $CLEAN_ANSIBLE_ROLES ] && rm -rf "$CUSTOM_ANSIBLE_ROLES_PATH"
    git clone git@github.com:cloudfactory/ops-automata.git "$CUSTOM_ANSIBLE_ROLES_PATH"
}

utils_install_dependent_roles(){
    # we need to install these roles 
    DEPENDENT_ROLES=( git+https://github.com/cloudfactory/ansible-prometheus.git franklinkim.newrelic )
    ansible-galaxy install "${DEPENDENT_ROLES[@]}"
}


# override 
bootstrap(){

    # rarely changing ones
    VAULT_PASS_FILE="$HOME/.vault_pass" # this is supposed to be present in JeOS

    [ -z "$SKIP_BOOTSTRAP" ] \
	&& ansible-pull -C ${BOOTSTRAP_BRANCH:-master} \
			--full \
			-U ${BOOTSTRAP_PLAYBOOK_URL:-https://github.com/thapakazi/jeos_bootstrap} \
			--accept-host-key ${BOOTSTRAP_PLAYBOOK:-main.yml} \
			--vault-password-file=${VAULT_PASS_FILE} \
			${ANSIBLE_DEBUG_FLAG}
}

deployment(){

    # get the keys first
    su - deploy -c 'utils_pull_private_key'

    #safely assuming, bootstrap layers above successfully completed.
    for file in  /etc/profile.d/cloudfactory_utils*; do source $file; done

    export ANSIBLE_ROLES_PATH="$CUSTOM_ANSIBLE_ROLES_PATH"
    DEPLOYMENT_BRANCH="${DEPLOYMENT_BRANCH:-master}"
    DEPLOYMENT_PLAYBOOK="${DEPLOYMENT_PLAYBOOK:-main.yml}" # when deploying services: mongo/redis, this might come handy
    DEPLOYMENT_PLAYBOOK_PATH="${DEPLOYMENT_PLAYBOOK_PATH:-config/.meta/$DEPLOYMENT_PLAYBOOK}"
    DEPLOYMENT_SKIP_TAGS="${DEPLOYMENT_SKIP_TAGS:-ec2spin,ansicap}"

    # rarely changing ones
    DEPLOYMENT_GITHUB_REPO="$PROJECT"
    DEPLOYMENT_TMP_PULL_DIR="$USERDATA_TMPDIR/$DEPLOYMENT_GITHUB_REPO"

    ansible-pull -C ${DEPLOYMENT_BRANCH} \
		 --full -d ${DEPLOYMENT_TMP_PULL_DIR} \
		 -U git@${DEPLOYMENT_GITHUB_URL:-"github.com:cloudfactory/$DEPLOYMENT_GITHUB_REPO"}.git  \
		 --accept-host-key $DEPLOYMENT_PLAYBOOK_PATH  \
		 --skip-tags=${DEPLOYMENT_SKIP_TAGS} \
		 ${ANSIBLE_DEBUG_FLAG}
}

post_cleanup(){
    echo "Post cleanup actions: removing the ${PRIVATE_KEY_IN_LOCAL}"
    # improve it later, i know hardcoding sucks
    rm -rf ~/.ssh/id_rsa ~deploy/.ssh/id_rsa

    # in future we would remove user data dir itself
    # rm -rf $USERDATA_TMPDIR

    # in cases like, we need to clean up the cloud-init files, such that userdata could run on next boot
    # rm /var/lib/cloud/instance/{sem/config_scripts_user,boot-finished}
}


utils_export_home(){
    [ "$(/usr/bin/id -u)" = "0" ] && export HOME=/root || export HOME="/home/$(whoami)"
}


# 
# Purpose: this is a temporary helper script to finalise autoscaling scripts
#
# InsideIt:  it pulls private key from s3, scale repo from gitub and runs code-deploy.yml(ansicap and puts runit sidekiq run script)
utils_ansicap_with_sidekiq_supervise(){
    BOOTSTRAP_BRANCH="${BOOTSTRAP_BRANCH:-master}"
    BOOTSTRAP_PLAYBOOK="${BOOTSTRAP_PLAYBOOK:-code-deploy.yml}"

    BOOTSTRAP_GITHUB_URL="github.com:cloudfactory/scale"
    BOOTSTRAP_TMP_PULL_DIR="$USERDATA_TMPDIR/scale"

    # we might need it somewhere while doing bundle install
    utils_pull_private_key # safely assuming bucket name and region is exposed early on the call stack.
    [ -z "$SKIP_ANSICAP" ] \
	&& ansible-pull -C $BOOTSTRAP_BRANCH \
			--full -d ${BOOTSTRAP_TMP_PULL_DIR} \
			-i 'localhost' -U git@${BOOTSTRAP_GITHUB_URL}.git \
			--accept-host-key $BOOTSTRAP_PLAYBOOK -vvvv
}

# 
# Purpose: this funciton is used to notify rocketchat. Mean while it also configures slacktee if its absent
#          more on slacktee: https://github.com/course-hero/slacktee
# InsideIt:  it configures slacktee if its absent and send msg to rocketchat in #dump room, whatever is thrown to it
#           slacktee config(/etc/slacktee.conf) is pulled from s3, if its absent
utils_notify_slack(){
    # check if slacktee is present, else get it
    SLACKTEE_BIN='/usr/local/bin/slacktee'
    SLACKTEE_CONFIG='/etc/slacktee.conf'
    SLACKTEE_GITHUB='https://github.com/course-hero/slacktee'
    SLACKTEE_CLONE_LOCAL=$USERDATA_TMPDIR/slacktee
    SLACKTEE_CONFIG_IN_S3="${SLACKTEE_CONFIG_IN_S3:-my_s3bucket/autoscaling/.slacktee}"
    # check if config's present, else configure
    [ -f $SLACKTEE_BIN ] \
	|| { git clone $SLACKTEE_GITHUB $SLACKTEE_CLONE_LOCAL \
		 && cp $SLACKTEE_CLONE_LOCAL/slacktee.sh $SLACKTEE_BIN \
		 && chmod +x $SLACKTEE_BIN
	}

    [ -f $SLACKTEE_CONFIG ] \
	|| { \
	     aws s3 cp s3://$SLACKTEE_CONFIG_IN_S3 $SLACKTEE_CONFIG \
		 && echo "$(date) first time: just pulled the configs, sending test msg from $(hostnamectl --static)"| $SLACKTEE_BIN
	}
    # send msg to #dump
    echo "$@"|$SLACKTEE_BIN -c "#dump"  # explicitly hardcoding the room name

}

utils_notify_and_post_cleanup(){
    post_cleanup
    utils_notify_slack "From: $(hostnamectl --static): $(date): **** $(tail -n 20 $USERDATA_TMPDIR/pull.log)"
}
