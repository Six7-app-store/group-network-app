locals {
  access_ipv4 = { for key, vm in local.vms : key => (
    local.dual ? local.secondary_ipv4[key] :
    (var.ip_mode == "ipv4" ? try([for ip in openstack_networking_port_v2.access[key].all_fixed_ips : ip if !strcontains(ip, ":")][0], null) : null)
  ) }
  access_ipv6 = { for key, vm in local.vms : key => local.ipv6 ? try([for ip in openstack_networking_port_v2.access[key].all_fixed_ips : ip if strcontains(ip, ":")][0], null) : null }
  access_ip   = { for key, vm in local.vms : key => var.ip_mode == "ipv6" ? local.access_ipv6[key] : local.access_ipv4[key] }
  lab_ipv4    = { for key, vm in local.vms : key => local.ipv4 ? cidrhost(openstack_networking_subnet_v2.group[vm.team].cidr, vm.index + 10) : null }
  lab_ipv6    = { for key, vm in local.vms : key => local.ipv6 ? cidrhost(openstack_networking_subnet_v2.group_v6[vm.team].cidr, vm.index + 10) : null }
}
output "user_accounts" {
  description = "SSH to the first VM; the same account works on all group VMs"
  sensitive   = true
  value = {
    for uid, user in local.users_map : "${user.team}-${replace(split("@", user.email)[0], "/[^a-zA-Z0-9]/", "-")}" => {
      type     = "password"
      protocol = "ssh"
      email    = user.email
      team     = user.team
      ip       = local.access_ip["${user.team}/1"]
      port     = 22
      username = user.username
      auth     = random_password.user_passwords[uid].result
    }
  }
}
output "team_vms" {
  description = "Legacy first-VM fields plus full group inventory"
  value = {
    for team in local.teams : team => {
      instance_id   = openstack_compute_instance_v2.vm["${team}/1"].id
      instance_name = openstack_compute_instance_v2.vm["${team}/1"].name
      ip_mode       = var.ip_mode
      fixed_ip      = local.access_ip["${team}/1"]
      fixed_ip_v4   = local.access_ipv4["${team}/1"]
      fixed_ip_v6   = local.access_ipv6["${team}/1"]
      floating_ip   = null
      url           = null
      network_id    = openstack_networking_network_v2.group[team].id
      subnet_id     = local.ipv4 ? openstack_networking_subnet_v2.group[team].id : openstack_networking_subnet_v2.group_v6[team].id
      subnet_id_v4  = local.ipv4 ? openstack_networking_subnet_v2.group[team].id : null
      subnet_id_v6  = local.ipv6 ? openstack_networking_subnet_v2.group_v6[team].id : null
      vms = {
        for key, vm in local.vms : tostring(vm.index) => {
          instance_id   = openstack_compute_instance_v2.vm[key].id
          instance_name = openstack_compute_instance_v2.vm[key].name
          access_ip     = local.access_ip[key]
          fixed_ip_v4   = local.access_ipv4[key]
          fixed_ip_v6   = local.access_ipv6[key]
          lab_ip        = var.ip_mode == "ipv6" ? local.lab_ipv6[key] : local.lab_ipv4[key]
          lab_ip_v4     = local.lab_ipv4[key]
          lab_ip_v6     = local.lab_ipv6[key]
          ssh_host      = var.ip_mode == "ipv6" ? local.access_ipv6[key] : local.access_ipv4[key]
        } if vm.team == team
      }
    }
  }
  precondition {
    condition     = alltrue([for key, vm in local.vms : local.access_ip[key] != null && (!local.ipv6 || local.access_ipv6[key] != null)])
    error_message = "The selected access networks must supply addresses for every requested IP family. NAT IPv4 is not used as an IPv6 access target."
  }
}
output "teams_summary" {
  value = { for team, members in var.users : team => length(members) }
}
