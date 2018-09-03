#!/usr/bin/env bash

$environments = Get-EBEnvironment |?{$_.Status -match 'ready' }

$environments = Get-EBEnvironment |?{$_.Status -match 'ready' }
$url = $environments | Select -First 1 | %{ $_.EndpointUrl }

Write-Host "The endpoint url is $url"

$payload = @'
{"is_paid": false, "amount": 1664, "due_date": "2016-05-07T23:00:00Z", "charges": [ { "type":"blood work", "amount": 1664, "description": "blood work" } ] }
@' 

Invoke-RestMethod `
  -Method Post `
  -Body $payload `
  -Uri "http://$url/invoice"

Invoke-RestMethod `
  -Method Get `
  -Uri "http://$url/invoice/1"

# Post the example

curl -X POST \
    --data '{"is_paid": false, "amount": 1664, "due_date": "2016-05-07T23:00:00Z", "charges": [ { "type":"blood work", "amount": 1664, "description": "blood work" } ] }' \
    http://$url/invoice

curl http://$url/invoice/1

echo $url


# Should be something like: 
{"ID":1,"CreatedAt":"2016-05-21T15:33:21.855874Z","UpdatedAt":"2016-05-21T15:33:21.855874Z","DeletedAt":null,"is_paid":false,"amount":1664,"payment_date":"0001-01-01T00:00:00Z","due_date":"2016-05-07T23:00:00Z","charges":[{"ID":1,"CreatedAt":"2016-05-21T15:33:21.8637Z","UpdatedAt":"2016-05-21T15:33:21.8637Z","DeletedAt":null,"invoice_id":1,"type":"blood
work","amount":1664,"description":"blood work"}]}
















