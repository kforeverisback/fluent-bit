# Deploy DCR Template

## Prereq

- Log Analytics
- Data Congestion Endpoint (DCE)

## Create DCR with `az cli`

```bash
DCR=<name>
SUB=77755556-abcd-abcd-a23d-166151412122
RG=<value>
az deployment group create \
  --name "deploy-dcr" \
  --resource-group <RG_NAME> \
  --template-file dcr-template.json \
  --parameters dataCollectionRuleName=<DCR_NAME> \
  --parameters location=eastus \
  --parameters workspaceResourceId=<FULL_RSRC_ID> \
  --parameters endpointResourceId=<DCE_FULL_RSRC_ID>
  ```

Afterwards, create a service principal with secret and assign the `Monitoring Metrics Publisher` role to your Microsoft Entra application on the DCR. This role grants the Microsoft.Insights/Telemetry/Write permission that the Logs ingestion API requires.

Follow [this tutorial](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/tutorial-logs-ingestion-portal) for more info.
