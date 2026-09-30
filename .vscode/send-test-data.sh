#!/usr/bin/env bash
#
# Send test data to the Custom-Syslog stream of the DCR defined in
# dcr-template.json (output stream: Microsoft-Syslog).
#
# Equivalent of the PowerShell sample in:
# https://learn.microsoft.com/en-us/azure/azure-monitor/logs/tutorial-logs-ingestion-portal
#
# Required environment variables (or use the CLI flags below):
#   AZURE_TENANT_ID       Entra ID tenant ID
#   AZURE_CLIENT_ID       App registration (service principal) client ID
#   AZURE_CLIENT_SECRET   App registration client secret
#   DCE_ENDPOINT          Logs ingestion URI of the DCE,
#                         e.g. https://my-dce-abcd.eastus-1.ingest.monitor.azure.com
#   DCR_IMMUTABLE_ID      Immutable ID of the DCR, e.g. dcr-000000000000000000000000
#
# Optional:
#   STREAM_NAME           Defaults to Custom-Syslog
#   AZURE_CLOUD_AUDIENCE  Defaults to https://monitor.azure.com
#
# The app registration needs the "Monitoring Metrics Publisher" role on the DCR.

set -euo pipefail

env_file="$(dirname "$0")/.env"
if [[ -f "$env_file" ]]; then
    echo "Sourcing $env_file"
    source "$env_file"
fi

STREAM_NAME="${STREAM_NAME:-Custom-Syslog}"
AZURE_CLOUD_AUDIENCE="${AZURE_CLOUD_AUDIENCE:-https://monitor.azure.com}"
PAYLOAD_FILE=""
RECORD_COUNT=2
VERBOSE=0
DRY_RUN=0
NDJSON=0
LOOP_DELAY=0
ITERATIONS=0

usage()
{
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --tenant-id ID          Entra ID tenant ID (env AZURE_TENANT_ID)
  --client-id ID          App registration client ID (env AZURE_CLIENT_ID)
  --client-secret SECRET  App registration secret (env AZURE_CLIENT_SECRET)
  --dce-endpoint URL      DCE logs ingestion URI (env DCE_ENDPOINT)
  --dcr-immutable-id ID   DCR immutable ID (env DCR_IMMUTABLE_ID)
  --stream NAME           Stream name (default: ${STREAM_NAME})
  --payload FILE          JSON array file to send instead of generated sample data
  --count N               Number of generated sample records (default: ${RECORD_COUNT})
  --dry-run               Print the JSON payload only; no token request, no upload
  --ndjson                Print one compact JSON record per line (implies --dry-run
                          formatting; handy for fluent-bit dummy/tail input)
  --loop SECONDS          Dry-run only: keep printing batches of --count records,
                          waiting SECONDS between batches (fractional values ok,
                          Ctrl-C to stop)
  --iterations N          With --loop: stop after N batches (default: 0 = infinite)
  --verbose               Print the request payload
  -h, --help              Show this help

Prefer passing secrets via environment variables; command-line arguments are
visible to other users through the process list.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --tenant-id)         AZURE_TENANT_ID="$2"; shift 2 ;;
        --client-id)         AZURE_CLIENT_ID="$2"; shift 2 ;;
        --client-secret)     AZURE_CLIENT_SECRET="$2"; shift 2 ;;
        --dce-endpoint)      DCE_ENDPOINT="$2"; shift 2 ;;
        --dcr-immutable-id)  DCR_IMMUTABLE_ID="$2"; shift 2 ;;
        --stream)            STREAM_NAME="$2"; shift 2 ;;
        --payload)           PAYLOAD_FILE="$2"; shift 2 ;;
        --count)             RECORD_COUNT="$2"; shift 2 ;;
        --dry-run)           DRY_RUN=1; shift ;;
        --ndjson)            NDJSON=1; DRY_RUN=1; shift ;;
        --loop)              LOOP_DELAY="$2"; DRY_RUN=1; shift 2 ;;
        --iterations)        ITERATIONS="$2"; shift 2 ;;
        --verbose)           VERBOSE=1; shift ;;
        -h|--help)           usage; exit 0 ;;
        *)                   echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

for cmd in curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "error: '$cmd' is required but not installed" >&2
        exit 1
    fi
done

if [ "$DRY_RUN" -eq 0 ]; then
    for var in AZURE_TENANT_ID AZURE_CLIENT_ID AZURE_CLIENT_SECRET DCE_ENDPOINT DCR_IMMUTABLE_ID; do
        if [ -z "${!var:-}" ]; then
            echo "error: $var is not set" >&2
            exit 1
        fi
    done

    DCE_ENDPOINT="${DCE_ENDPOINT%/}"

    # 1. Client credentials flow against Entra ID.
    token_response=$(curl -sS -X POST \
        "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "client_id=${AZURE_CLIENT_ID}" \
        --data-urlencode "client_secret=${AZURE_CLIENT_SECRET}" \
        --data-urlencode "scope=${AZURE_CLOUD_AUDIENCE}/.default" \
        --data-urlencode "grant_type=client_credentials")

    access_token=$(printf '%s' "$token_response" | jq -r '.access_token // empty')
    if [ -z "$access_token" ]; then
        echo "error: failed to acquire token:" >&2
        printf '%s\n' "$token_response" | jq . >&2 || printf '%s\n' "$token_response" >&2
        exit 1
    fi
fi

# 2. Build the payload matching the Custom-Syslog stream declaration.
build_payload()
{
    local now
    local sev
    sev=${2:-"info"}
    local process
    process=${3:-"logs-ingestion-test"}

    if [ -n "$PAYLOAD_FILE" ]; then
        jq -c . "$PAYLOAD_FILE"
        return
    fi

    now=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
    jq -cn \
        --arg ts "$now" \
        --arg computer "$(hostname)" \
        --arg process "$process" \
        --arg sev "$sev" \
        --argjson count "$RECORD_COUNT" \
        '[range(0; $count) | {
            TimeGenerated: $ts,
            Computer: $computer,
            Facility: "user",
            HostIP: "10.0.0.10",
            HostName: $computer,
            ProcessID: (1000 + .),
            ProcessName: $process,
            SeverityLevel: $sev,
            SyslogMessage: ("test message \(.) from logs ingestion API")
        }]'
}

print_payload()
{
    if [ "$NDJSON" -eq 1 ]; then
        printf '%s' "$1" | jq -c '.[]'
    else
        printf '%s' "$1" | jq .
    fi
}

if [ -n "$PAYLOAD_FILE" ] && [ ! -r "$PAYLOAD_FILE" ]; then
    echo "error: cannot read payload file: $PAYLOAD_FILE" >&2
    exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$LOOP_DELAY" != "0" ]; then
        i=0
        while [ "$ITERATIONS" -eq 0 ] || [ "$i" -lt "$ITERATIONS" ]; do
            print_payload "$(build_payload)"
            i=$((i + 1))
            if [ "$ITERATIONS" -ne 0 ] && [ "$i" -ge "$ITERATIONS" ]; then
                break
            fi
            sleep "$LOOP_DELAY"
        done
        exit 0
    fi
    print_payload "$(build_payload)"
    exit 0
fi

payload=$(build_payload)

if [ "$VERBOSE" -eq 1 ]; then
    printf 'Payload:\n%s\n' "$(printf '%s' "$payload" | jq .)"
fi

# 3. Upload to the DCR stream.
url="${DCE_ENDPOINT}/dataCollectionRules/${DCR_IMMUTABLE_ID}/streams/${STREAM_NAME}?api-version=2023-01-01"
echo "POST ${url}"

http_code=$(curl -sS -o /tmp/dcr-ingest-response.$$ -w '%{http_code}' \
    -X POST "$url" \
    -H "Authorization: Bearer ${access_token}" \
    -H "Content-Type: application/json" \
    --data-binary "$payload")

body=$(cat "/tmp/dcr-ingest-response.$$")
rm -f "/tmp/dcr-ingest-response.$$"

if [ "$http_code" = "204" ]; then
    echo "OK: data accepted (HTTP 204). Query the Syslog table in a few minutes."
    exit 0
fi

echo "error: ingestion failed (HTTP ${http_code})" >&2
if [ -n "$body" ]; then
    printf '%s\n' "$body" | jq . >&2 || printf '%s\n' "$body" >&2
fi
exit 1
