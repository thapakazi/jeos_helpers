# Name: this function's sole purpose is to pull ssh key for user
# Usage:
#   $ su - user -c ' utils_pull_private_key '
#   like: export PRIVATE_KEY_PATH_IN_S3=mybucketname/path/to/my/private_key && su - user -c 'utils_pull_private_key'
#      if your key is in other bucket and other path
utils_pull_private_key (){
    
    SSH_DIR="$HOME/.ssh" && mkdir -p $SSH_DIR
    PRIVATE_KEY_IN_LOCAL="${SSH_DIR}/id_rsa"

    REGION="${REGION:-my-region-1}"
    PRIVATE_KEY_PATH_IN_S3="${PRIVATE_KEY_PATH_IN_S3:-my_s3bucket/autoscaling/id_rsa}"

    # asuming awscli is already in JEOS
    aws s3 cp s3://${PRIVATE_KEY_PATH_IN_S3} ${PRIVATE_KEY_IN_LOCAL} --region ${REGION}
    chmod 400 ${PRIVATE_KEY_IN_LOCAL}

    # if you reached this far
    echo "#SECURITY :: PLEASE CLEAN UP THE FILE $PRIVATE_KEY_IN_LOCAL"
    echo "#SECURITY :: rm -rf $PRIVATE_KEY_IN_LOCAL"
}
