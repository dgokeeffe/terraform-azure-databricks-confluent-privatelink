# Customer response - Confluent Private Link transit architecture

> Delete this file before final push. For drafting only.

---

Subject: **Correction to Confluent Private Link transit architecture - updated repo with working solutions**

Hi [Customer],

Thank you for flagging the issue with the transit architecture I shared. You're right - Azure Standard Load Balancers cannot use Private Endpoint IPs as backend pool targets. This is an Azure platform limitation that I missed when building the original module. I apologise for the confusion and any time spent debugging this.

I've updated the repository with two working alternatives that correctly route traffic from Databricks Serverless to Confluent Cloud over Private Link:

## Option A: Application Gateway v2 with TCP proxy

- Uses Azure App GW v2 as a managed TCP proxy (port 9092)
- App GW v2 supports PE IPs as backend targets (unlike Standard LB)
- Has native Private Link support, so no separate PLS is needed
- Databricks NCC PE rule targets the App GW directly
- **Trade-off**: App GW TCP proxy is currently in preview and requires the `azapi` Terraform provider (the `azurerm` provider doesn't support TCP listeners yet)

## Option B: VMSS with HAProxy behind Standard Load Balancer

- VMSS instances running HAProxy act as the TCP proxy layer
- Standard LB backends are the VMSS instances (real VMs), not PE IPs
- A Private Link Service exposes the LB to Databricks NCC
- HAProxy on each VM forwards TCP traffic to the Confluent PE IP
- **Trade-off**: You manage the VMs (patching, scaling), but all components are GA

Both options are fully documented with examples in the updated repo:
https://github.com/dgokeeffe/terraform-azure-databricks-confluent-privatelink

I'd recommend **Option A** for production workloads if you're comfortable with the preview status, or **Option B** if you need GA components and want full control. Happy to walk through either option in more detail.

Again, sorry for the incorrect original architecture. Let me know if you have any questions or want to schedule time to go through the deployment.

Best,
David
