#!/usr/bin/env bash

# requires: pip install awscli awsebcli

#dockerusername="actionablelabs"
#githubusername="actionable-labs"

### Script header

while getopts "d:g:" option; do
    case "${option}" in
    d) dockerusername=$OPTARG ;;
    g) githubusername=$OPTARG ;;
    esac
done

if [[ $dockerusername &&  $githubusername ]]
then 
  echo "docker: $dockerusername; github: $githubusername"
else
  echo ""
  echo "usage: "
  echo "  ./create_ebs_env.sh -d <dockerusername> -g <githubusername>"
  exit
fi

# uncomment to debug
#set -x

# The latest events can be found at 
#cat tmp/$identifier/eb-events*.json |less

##############################
# Run as a script.
##########################

# Don't set this variable if you are copy/pasting or vim-sliming
EXEC_AS_SCRIPT=true

PS1="#> " 


##############################
# Create a fail condition
##########################
fail() {
    echo configuration failed
    if [ $EXEC_AS_SCRIPT ] ; 
      then exit 1; 
      else echo "failed in terminal";
    fi
}


##############################
# Set up environment for this run
##########################
export AWS_DEFAULT_REGION=${AWS_REGION:-us-east-2}
datetag=$(date +%Y%m%d%H%M)
identifier=$(whoami)-invoicer-$datetag
mkdir -p tmp/$identifier




##############################
# Get the VPC Id
##########################
clear
echo "Creating EBS application $identifier"
# Find the ID of the default VPC
aws ec2 describe-vpcs --filters Name=isDefault,Values=true > tmp/$identifier/defaultvpc.json || fail
vpcid=$(jq -r '.Vpcs[0].VpcId' tmp/$identifier/defaultvpc.json)
echo "default vpc is $vpcid"


##############################
# Creating the database:
# - Create Security Group
# - Create RDS database
# - Wait while RDS is created
# - Add tags to the database
##########################

# Create a security group for the database
aws ec2 create-security-group \
    --group-name $identifier \
    --description "access control to Invoicer Postgres DB" \
    --vpc-id $vpcid > tmp/$identifier/dbsg.json || fail
dbsg=$(jq -r '.GroupId' tmp/$identifier/dbsg.json)
echo "DB security group is $dbsg"

# Create the database
dbinstclass="db.t2.micro"
dbstorage=5
dbpass=$(dd if=/dev/urandom bs=128 count=1 2>/dev/null| tr -dc _A-Z-a-z-0-9)
aws rds create-db-instance \
    --db-name invoicer \
    --db-instance-identifier "$identifier" \
    --vpc-security-group-ids "$dbsg" \
    --allocated-storage "$dbstorage" \
    --db-instance-class "$dbinstclass" \
    --engine postgres \
    --engine-version 9.6.2 \
    --auto-minor-version-upgrade \
    --publicly-accessible \
    --master-username invoicer \
    --master-user-password "$dbpass" \
    --no-multi-az > tmp/$identifier/rds.json || fail
echo "RDS Postgres database is being created. username=invoicer; password='$dbpass'"

# Retrieve the database hostname
while true;
do
    echo "aws rds describe-db-instances --db-instance-identifier $identifier"
    aws rds describe-db-instances --db-instance-identifier $identifier > tmp/$identifier/rds.json
    clear
    echo "aws rds describe-db-instances --db-instance-identifier $identifier"
    cat tmp/$identifier/rds.json
    dbhost=$(jq -r '.DBInstances[0].Endpoint.Address' tmp/$identifier/rds.json)
    dbstatus=$(jq -r '.DBInstances[0].DBInstanceStatus' tmp/$identifier/rds.json)
    echo "Database status: $dbstatus"
    date
    if [[ "$dbhost" != "null" && "$dbstatus" == "available" ]]; then break; fi
    #if [ "$dbstatus" != "deleting" ]; then break; fi
    echo -n '.'
    sleep 10
done
echo "dbhost=$dbhost"

# tagging rds instance
dbarn=$(jq -r '.DBInstances[0].DBInstanceArn' tmp/$identifier/rds.json) 
aws rds add-tags-to-resource \
    --resource-name $dbarn
    --tags "Key=environment-name,Value=invoicer-api"
aws rds add-tags-to-resource \
    --resource-name $dbarn
    --tags "Key=Owner,Value=$(whoami)"
aws rds list-tags-for-resource \
    --resource-name $dbarn


##############################
# Creating the beanstalk:
# - Create beanstalk application
# - Create environment configuration file
# - Create the environment
# - Wait for the environment to be created
##########################

# Create an elasticbeantalk application
aws elasticbeanstalk create-application \
    --application-name $identifier \
    --description "Invoicer $env $datetag" > tmp/$identifier/ebcreateapp.json || fail
echo "ElasticBeanTalk application created"


# Get the name of the latest Docker solution stack
dockerstack="$(aws elasticbeanstalk list-available-solution-stacks \
    | jq -r '.SolutionStacks[]' | grep -P '.+Amazon Linux.+v2\.7.+Docker.+' | head -1)"
echo "dockerstack is '$dockerstack'"

# Create the EB API environment
sed "s/POSTGRESPASSREPLACEME/$dbpass/" ebs-options.json > tmp/$identifier/ebs-options.json || fail
sed -i "s/POSTGRESHOSTREPLACEME/$dbhost/" tmp/$identifier/ebs-options.json || fail
cat tmp/$identifier/ebs-options.json 

aws elasticbeanstalk create-environment \
    --application-name $identifier \
    --environment-name $identifier-inv-api \
    --description "Invoicer API environment" \
    --tags "Key=Owner,Value=$(whoami)" \
    --solution-stack-name "$dockerstack" \
    --option-settings file://tmp/$identifier/ebs-options.json \
    --tier "Name=WebServer,Type=Standard,Version=''" > tmp/$identifier/ebcreateapienv.json || fail

apieid=$(jq -r '.EnvironmentId' tmp/$identifier/ebcreateapienv.json)
echo "API environment $apieid is being created"

sleep 10
aws elasticbeanstalk describe-environment-resources --environment-id $apieid > tmp/$identifier/ebapidesc.json || fail
ec2id=$(jq -r '.EnvironmentResources.Instances[0].Id' tmp/$identifier/ebapidesc.json)
date
echo "ec2id is $ec2id"


clear
# grab the instance ID of the API environment, then its security group, and add that to the RDS security group
while true;
do
    aws elasticbeanstalk describe-environment-resources --environment-id $apieid > tmp/$identifier/ebapidesc.json || fail
    clear
    echo "aws elasticbeanstalk describe-environment-resources --environment-id $apieid"
    cat tmp/$identifier/ebapidesc.json
    ec2id=$(jq -r '.EnvironmentResources.Instances[0].Id' tmp/$identifier/ebapidesc.json)
    date
    echo "ec2id is $ec2id"
    if [ "$ec2id" != "null" ]; then break; fi
    echo -n '.'
    sleep 10
done
echo
aws ec2 describe-instances --instance-ids $ec2id > tmp/$identifier/${ec2id}.json || fail
sgid=$(jq -r '.Reservations[0].Instances[0].SecurityGroups[0].GroupId' tmp/$identifier/${ec2id}.json)
aws ec2 authorize-security-group-ingress --group-id $dbsg --source-group $sgid --protocol tcp --port 5432 || fail
echo "API security group $sgid authorized to connect to database security group $dbsg"




##############################
# Creating the application version
# - Create a bucket and upload version configuration
# - Create the application version
# - Wait for the application version to update environment
##########################

# Upload the application version
aws s3 mb s3://$identifier
aws s3 cp app-version.json s3://$identifier/

aws elasticbeanstalk create-application-version \
    --application-name "$identifier" \
    --version-label invoicer-api \
    --source-bundle "S3Bucket=$identifier,S3Key=app-version.json" > tmp/$identifier/app-version-s3.json

# Wait for the environment to be ready (green)
echo -n "waiting for environment"
while true; do
    aws elasticbeanstalk describe-environments --environment-id $apieid > tmp/$identifier/$apieid.json
    clear
    echo "aws elasticbeanstalk describe-environments --environment-id $apieid"
    cat tmp/$identifier/$apieid.json
    health="$(jq -r '.Environments[0].Health' tmp/$identifier/$apieid.json)"
    date
    echo "Health is $health"
    if [ "$health" == "Green" ]; then break; fi
    echo -n '.'
    sleep 10
done
echo




##############################
# Deploy the application
# - Deploy by updating the environment
# - TODO: Wait for deployment
##########################

# Deploy the docker container to the instances
aws elasticbeanstalk update-environment \
    --application-name $identifier \
    --environment-id $apieid \
    --version-label invoicer-api > tmp/$identifier/$apieid.json

url="$(jq -r '.CNAME' tmp/$identifier/$apieid.json)"
echo "Environment is being deployed. Public endpoint is http://$url"

