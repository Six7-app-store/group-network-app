output "user_accounts" {
  description = "SSH to the first VM; the same account works on all group VMs"
  sensitive   = true
  value = {
    for uid, user in local.users_map : "${user.team}-${replace(split("@", user.email)[0], "/[^a-zA-Z0-9]/", "-")}" => {
      type     = "password"
      protocol = "ssh"
      email    = user.email
      ip       = openstack_networking_port_v2.access["${user.team}/1"].all_fixed_ips[0]
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
      fixed_ip      = openstack_networking_port_v2.access["${team}/1"].all_fixed_ips[0]
      floating_ip   = null
      url           = null
      network_id    = openstack_networking_network_v2.group[team].id
      subnet_id     = openstack_networking_subnet_v2.group[team].id
      vms = {
        for key, vm in local.vms : tostring(vm.index) => {
          instance_id   = openstack_compute_instance_v2.vm[key].id
          instance_name = openstack_compute_instance_v2.vm[key].name
          access_ip     = openstack_networking_port_v2.access[key].all_fixed_ips[0]
          lab_ip        = cidrhost(openstack_networking_subnet_v2.group[team].cidr, vm.index + 10)
        } if vm.team == team
      }
    }
  }
}
output "teams_summary" {
  value = { for team, members in var.users : team => length(members) }
}
