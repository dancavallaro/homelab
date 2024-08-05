#!/usr/bin/env bash

METRIC_NAMESPACE="RPiMonitoring"
METRIC_NAME="Temperature"

temperature=$(sensors -jf | jq '."cpu_thermal-virtual-0".temp1.temp1_input')

/usr/local/bin/aws --region us-east-1 \
	cloudwatch put-metric-data \
	--namespace "${METRIC_NAMESPACE}" --metric-name "${METRIC_NAME}" --value "${temperature}"
