# Reproduce the deployed worker payload: users and ordinary settings only.
# Do not globally supply the infrastructure variables whose omission failed.
mock_provider "openstack" {
  mock_resource "openstack_networking_port_v2" {
    defaults = {
      all_fixed_ips = ["192.0.2.10", "2001:db8::10"]
      mac_address   = "fa:16:3e:00:00:01"
    }
  }
  mock_data "openstack_networking_network_v2" {
    defaults = { id = "named-primary" }
  }
  mock_data "openstack_networking_subnet_v2" {
    defaults = { cidr = "192.0.2.0/24", gateway_ip = "192.0.2.1" }
  }
}
mock_provider "random" {}
variables {
  users = {
    "Team #1"      = [{ email = "alice@example.test" }]
    "Leere Gruppe" = []
  }
}
override_data {
  target = data.openstack_networking_network_v2.access_v4[0]
  values = { id = "named-ipv4" }
}
run "worker_payload_ipv6" {
  command = apply
  assert {
    condition     = data.openstack_networking_network_v2.access[0].name == "DHBWV6" && alltrue([for port in openstack_networking_port_v2.access : port.network_id == "named-primary" && port.security_group_ids == toset([openstack_networking_secgroup_v2.access[0].id])])
    error_message = "Minimal worker input must resolve DHBWV6 and attach the automatic SSH group."
  }
  assert {
    condition     = length(openstack_networking_secgroup_rule_v2.access_ssh) == 1 && openstack_networking_secgroup_rule_v2.access_ssh["IPv6"].port_range_min == 22 && openstack_networking_secgroup_rule_v2.access_icmp["IPv6"].protocol == "ipv6-icmp" && length(openstack_networking_secgroup_rule_v2.access_egress) == 2 && output.team_vms["Team #1"].fixed_ip == "2001:db8::10"
    error_message = "IPv6 needs SSH/ICMPv6 ingress, both egress families and an IPv6 access target."
  }
}
run "worker_payload_ipv4" {
  command = apply
  variables { ip_mode = "ipv4" }
  assert {
    condition     = data.openstack_networking_network_v2.access[0].name == "DHBWv4" && length(openstack_networking_secgroup_rule_v2.access_ssh) == 1 && openstack_networking_secgroup_rule_v2.access_ssh["IPv4"].port_range_min == 22 && output.team_vms["Team #1"].fixed_ip == "192.0.2.10"
    error_message = "IPv4 minimal input must choose the IPv4 network and create working SSH rules."
  }
}
run "worker_payload_dual" {
  command = apply
  variables { ip_mode = "dual" }
  assert {
    condition     = data.openstack_networking_network_v2.access[0].name == "DHBWV6" && data.openstack_networking_network_v2.access_v4[0].name == "DHBWv4" && alltrue([for port in openstack_networking_port_v2.access_v4 : port.network_id == "named-ipv4" && port.security_group_ids == toset([openstack_networking_secgroup_v2.access[0].id])]) && length(openstack_networking_secgroup_rule_v2.access_ssh) == 2
    error_message = "Dual-stack omitted IDs must resolve distinct named networks and attach the SSH group to both NICs."
  }
}
run "explicit_project_inputs" {
  command = apply
  variables {
    ip_mode            = "dual"
    network_v4_uuid    = "chosen-v4-network"
    network_v6_uuid    = "chosen-v6-network"
    shared_secgroup_id = "chosen-access-group"
  }
  assert {
    condition     = length(data.openstack_networking_network_v2.access) == 0 && length(data.openstack_networking_network_v2.access_v4) == 0 && length(openstack_networking_secgroup_v2.access) == 0 && alltrue([for port in openstack_networking_port_v2.access : port.network_id == "chosen-v6-network" && port.security_group_ids == toset(["chosen-access-group"])]) && alltrue([for port in openstack_networking_port_v2.access_v4 : port.network_id == "chosen-v4-network" && port.security_group_ids == toset(["chosen-access-group"])])
    error_message = "Explicit project choices must override automatic defaults without widening the selected security group's rules."
  }
}
run "restricted_ssh_sources" {
  command = plan
  variables {
    ip_mode             = "dual"
    ssh_allowed_cidr_v4 = "192.0.2.0/24"
    ssh_allowed_cidr_v6 = "2001:db8::/32"
  }
  assert {
    condition     = openstack_networking_secgroup_rule_v2.access_ssh["IPv4"].remote_ip_prefix == "192.0.2.0/24" && openstack_networking_secgroup_rule_v2.access_ssh["IPv6"].remote_ip_prefix == "2001:db8::/32"
    error_message = "Automatic SSH rules must respect the configured client networks."
  }
}
run "no_members_no_infrastructure" {
  command = plan
  variables {
    users   = { "Leere Gruppe" = [] }
    ip_mode = "dual"
  }
  assert {
    condition     = length(openstack_networking_secgroup_v2.access) == 0 && length(data.openstack_networking_network_v2.access) == 0 && length(data.openstack_networking_network_v2.access_v4) == 0 && length(data.openstack_networking_subnet_v2.access_v4) == 0 && length(openstack_compute_instance_v2.vm) == 0
    error_message = "Empty rosters must not create security groups or require network lookups."
  }
}
run "legacy_uuid_override" {
  command = plan
  variables { network_uuid = "legacy-primary-network" }
  assert {
    condition     = length(data.openstack_networking_network_v2.access) == 0 && alltrue([for port in openstack_networking_port_v2.access : port.network_id == "legacy-primary-network"])
    error_message = "An existing network_uuid selection must take precedence over name defaults."
  }
}
run "ipv6_network_without_ipv6" {
  command = plan
  override_resource {
    target = openstack_networking_port_v2.access["Team #1/1"]
    values = { all_fixed_ips = ["10.200.0.10"] }
  }
  override_resource {
    target = openstack_networking_port_v2.access["Team #1/2"]
    values = { all_fixed_ips = ["10.200.0.11"] }
  }
  expect_failures = [output.team_vms]
}
