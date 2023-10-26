#!/usr/bin/env python

import boto3

sts = boto3.client("sts")
role = sts.assume_role(RoleArn="arn:aws:iam::484396241422:role/RPiMonitoringRole", RoleSessionName="rpi-monitoring")
creds = role["Credentials"]

print("[default]")
print(f"aws_access_key_id = {creds['AccessKeyId']}")
print(f"aws_secret_access_key = {creds['SecretAccessKey']}")
print(f"aws_session_token = {creds['SessionToken']}")
