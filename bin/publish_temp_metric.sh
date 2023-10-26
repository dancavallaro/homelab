#!/usr/bin/env bash

METRIC_NAMESPACE="RPiMonitoring"
METRIC_NAME="Temperature"

# Fetch the latest temp from the DHT22. The library prints a message when calling exit(),
# so only take the first line.
temperature=$(${0%/*}/temp.py | head -n 1)

/usr/local/bin/aws --region us-east-1 \
	cloudwatch put-metric-data \
	--namespace "${METRIC_NAMESPACE}" --metric-name "${METRIC_NAME}" --value "${temperature}"
