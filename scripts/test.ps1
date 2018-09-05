#!/usr/bin/env bash

function prompt { "PS$ " }

Import-Module AWSPowerShell.NetCore
Set-AWSCredentials -ProfileName 'default'
Set-DefaultAWSRegion 'us-east-2'

$environments = Get-EBEnvironment

$environments = Get-EBEnvironment |?{$_.Status -match 'ready' -and $_.Health -match "green" }
$url = $environments | Select -First 1 | %{ "http://" + $_.CNAME } 

Write-Host "The endpoint url is $url"

$payload = @"
{"is_paid": false, "amount": 1664, "due_date": "2016-05-07T23:00:00Z", "charges": [ { "type":"blood work", "amount": 1664, "description": "blood work" } ] }
"@ 

Invoke-RestMethod `
  -Method Post `
  -Body $payload `
  -Uri "$url/invoice"

$response = Invoke-RestMethod `
  -Method Get `
  -Uri "$url/invoice/1"
$response | ConvertTo-Json


