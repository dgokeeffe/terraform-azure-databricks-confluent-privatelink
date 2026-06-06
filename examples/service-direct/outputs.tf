output "private_endpoint_name" {
  description = "Name of the Azure private endpoint."
  value       = module.service_direct.private_endpoint_name
}

output "private_ip_address" {
  description = "Private IP assigned to the private endpoint."
  value       = module.service_direct.private_ip_address
}

output "dns_fqdn" {
  description = "Resolvable FQDN for service-direct (<region>.service-direct.privatelink.azuredatabricks.net)."
  value       = module.service_direct.dns_fqdn
}

output "endpoint_state" {
  description = "Account-side endpoint state. Must be APPROVED to be usable."
  value       = module.service_direct.endpoint_state
}

output "connection_summary" {
  description = "Summary of the service-direct configuration."
  value       = module.service_direct.connection_summary
}
