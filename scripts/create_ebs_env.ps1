#!/usr/bin/env bash

# requires: pip install awscli awsebcli

# uncomment to debug
#set -x

# Don't set this variable if you are copy/pasting or vim-sliming
$EXEC_AS_SCRIPT=$true



function prompt { 'PS$ ' }

Function Test-LastCmd  {
  if (-not $?) {
    Write-Host "configuration failed"
    if ($EXEC_AS_SCRIPT) { exit }
    else { Write-Host "failed in terminal" }
  }
}


Set-AWSCredential -ProfileName 'pp-psg'

#export AWS_DEFAULT_REGION=${AWS_REGION:-us-west-2}
Set-DefaultAWSRegion "us-west-2"

$datetag=(Get-Date -UFormat "%Y%m%d%H%M")
$identifier="{0}-invoicer-$datetag" -f (whoami)
mkdir -p tmp/$identifier


exit

# Notes. We left off with this.
#identifier=psgivens-invoicer-201806120644
#datetag="201806120644"

# The latest events can be found at 
#cat tmp/$identifier/eb-events*.json |less


clear
Write-Host "Creating EBS application $identifier"
# Find the ID of the default VPC

$vpc=Get-EC2Vpc -filter @{
  Name="isDefault";
  Values="true"
} 
Test-LastCmd
$vpc | ConvertTo-Json > tmp/$identifier/defaultvpc.json 
$vpcid=$vpc[0].VpcId
Write-Host "default vpc is $vpcid"

$dbsg = New-EC2SecurityGroup `
  -GroupName $identifier `
  -Description "Access control to Invoicer Postgres DB" `
  -VpcId $vpcid 
Test-LastCmd
$dbsg=$secGroup.GroupId
Write-Host "DB security group is $dbsg"

# Create the database
$dbinstclass="db.t2.micro"
$dbstorage=5
$dbpass=(dd if=/dev/urandom bs=128 count=1 2>$null | tr -dc _A-Z-a-z-0-9)

$dbinst = New-RDSDBInstance `
  -DbName invoicer `
  -DbInstanceIdentifier "$identifier" `
  -VpcSecurityGroupId "$dbsg" `
  -AllocatedStorage "$dbstorage" `
  -DBInstanceClass "$dbinstclass" `
  -Engine postgres `
  -EngineVersion "9.6.2" `
  -AutomInorVersionUpgrade $true `
  -PubliclyAccessible $true `
  -MasterUsername invoicer `
  -MasterUserPassword "$dbpass" `
  -MultiAZ $false 
Test-LastCmd
Write-Host "RDS Postgres database is being created. username=invoicer; password='$dbpass'"

# Retrieve the database hostname
while ($true) {
    clear
    Write-Host "Get-RDSDBInstance -DBInstanceIdentifier $identifier"
    $rds = Get-RDSDBInstance -DBInstanceIdentifier $identifier
    $rds | ConvertTo-Json > tmp/$identifier/rds.json
    clear
    Write-Host "Get-RDSDBInstance -DBInstanceIdentifier $identifier"
    $rds | ConvertTo-Json | Write-Host
    $dbhost= $rds.Endpoint.Address 
    $dbstatus= $rds.DBInstanceStatus 
    Write-Host "Database status: $dbstatus"
    Get-Date | Write-Host
    if ($dbhost -and $dbhost -notmatch "null" -and $dbstatus -match "available") { 
      break; }
    Start-Sleep -s 10
}
echo "dbhost=$dbhost"

# tagging rds instance
Add-RDSTagsToResource `
  -ResourceName $rds.DBInstanceArn `
  -Tags @{Key="environment-name";Value="invoicer-api"}
Add-RDSTagsToResource `
  -ResourceName $rds.DBInstanceArn `
  -Tags @{Key="Owner";Value=(whoami)}
Get-RDSTagForResource `
  -ResourceName $rds.DBInstanceArn

$eb = New-EBApplication `
  -ApplicationName $identifier `
  -Description "Invoicer $env $datetag"  
Write-Host "ElasticBeanTalk application created"
Test-LastCmd 


aws elasticbeanstalk list-available-solution-stacks  |less

$dockerstack= Get-EBAvailableSolutionStack `
  | %{ $_.SolutionStackDetails.SolutionStackName } `
  | Select-String -Pattern ".+Amazon Linux.+Docker.+" `
  | Select -First 1
Write-Host "dockerstack is '$dockerstack'"

# Create the EB API environment
sed "s/POSTGRESPASSREPLACEME/$dbpass/" ebs-options.json > tmp/$identifier/ebs-options.json 
Test-LastCmd
sed -i "s/POSTGRESHOSTREPLACEME/$dbhost/" tmp/$identifier/ebs-options.json 
Test-LastCmd
cat tmp/$identifier/ebs-options.json 

$eboptions = cat tmp/$identifier/ebs-options.json `
  | ConvertFrom-Json 

$ebenv = New-EBEnvironment `
  -ApplicationName $identifier `
  -EnvironmentName "$identifier-inv-api" `
  -Description "Invoicer API environment" `
  -Tags @{Key="Owner";Value=(whoami)} `
  -SolutionStackName "$dockerstack" `
  -OptionSettings $eboptions `
  -Tier_Name WebServer `
  -Tier_Type Standard `
  -Tier_Version ""
$ebenv | ConvertTo-Json > tmp/$identifier/ebcreateapienv.json 
Test-LastCmd
$apieid=$ebenv.EnvironmentId
Write-Host "API environment $apieid is being created"


# grab the instance ID of the API environment, then its security group, and add that to the RDS security group
while ($true){
  Write-Host "Get-EBEnvironmentResource -EnvironmentId $apieid"
  $envres = Get-EBEnvironmentResource -EnvironmentId $apieid
  $envres | ConvertTo-Json > tmp/$identifier/ebapidesc.json
  cat tmp/$identifier/ebapidesc.json
  Test-LastCmd
  clear
  Write-Host "Get-EBEnvironmentResource -EnvironmentId $apieid"
  cat tmp/$identifier/ebapidesc.json
  $ec2id=$envres.Instances[0].Id
  Get-Date | Write-Host
  Write-Host "ec2id is $ec2id"
  if ($ec2id) { break; } 
  Write-Host -n '.'
  Start-sleep 10
}
echo
$ec2inst = Get-EC2Instance -InstanceId $ec2id
$ec2inst | ConvertTo-Json > "tmp/$identifier/$ec2id.json"









##################################
# Left off here
###########################


sgid=$(jq -r '.Reservations[0].Instances[0].SecurityGroups[0].GroupId' tmp/$identifier/${ec2id}.json)


# cmdlet does not support old-style 'source-group'
Grant-EC2SecurityGroupIngress `
  -GroupId $dbsg `
  -SourceGroup $sgid `
  -Protocol tcp `
  -Port 5432 
Test-LastCmd










aws ec2 authorize-security-group-ingress --group-id $dbsg --source-group $sgid --protocol tcp --port 5432 
echo "API security group $sgid authorized to connect to database security group $dbsg"

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

# Deploy the docker container to the instances
aws elasticbeanstalk update-environment \
    --application-name $identifier \
    --environment-id $apieid \
    --version-label invoicer-api > tmp/$identifier/$apieid.json



url="$(jq -r '.CNAME' tmp/$identifier/$apieid.json)"
echo "Environment is being deployed. Public endpoint is http://$url"

echo $url

url=psgivens-invoicer-201806300737-inv-api.46mmped6da.us-west-2.elasticbeanstalk.com

# Post the example
curl -X POST \
    --data '{"is_paid": false, "amount": 1664, "due_date": "2016-05-07T23:00:00Z", "charges": [ { "type":"blood work", "amount": 1664, "description": "blood work" } ] }' \
    http://$url/invoice

curl http://$url/invoice/1

echo $url


# Should be something like: 
{"ID":1,"CreatedAt":"2016-05-21T15:33:21.855874Z","UpdatedAt":"2016-05-21T15:33:21.855874Z","DeletedAt":null,"is_paid":false,"amount":1664,"payment_date":"0001-01-01T00:00:00Z","due_date":"2016-05-07T23:00:00Z","charges":[{"ID":1,"CreatedAt":"2016-05-21T15:33:21.8637Z","UpdatedAt":"2016-05-21T15:33:21.8637Z","DeletedAt":null,"invoice_id":1,"type":"blood
work","amount":1664,"description":"blood work"}]}
















