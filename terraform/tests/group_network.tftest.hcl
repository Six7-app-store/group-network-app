mock_provider "openstack" {
  mock_resource "openstack_networking_port_v2" {
    defaults = {
      all_fixed_ips = ["192.0.2.10"]
      mac_address   = "fa:16:3e:00:00:01"
    }
  }
}
mock_provider "random" {}

variables {
  image_name         = "test-ubuntu"
  network_uuid       = "test-access-network"
  shared_secgroup_id = "test-access-sg"
  users = {
    alpha = [{ email = "alice@example.test" }]
    beta  = [{ email = "bob@example.test" }]
  }
}
override_resource {
  target = openstack_networking_network_v2.group["alpha"]
  values = { id = "alpha-network" }
}
override_resource {
  target = openstack_networking_network_v2.group["beta"]
  values = { id = "beta-network" }
}
override_resource {
  target = openstack_networking_secgroup_v2.group["alpha"]
  values = { id = "alpha-sg" }
}
override_resource {
  target = openstack_networking_secgroup_v2.group["beta"]
  values = { id = "beta-sg" }
}
run "group_topology" {
  command = apply
  assert {
    condition     = length(openstack_compute_instance_v2.vm) == 4 && length(openstack_networking_network_v2.group) == 2
    error_message = "Two groups must create four VMs and two exercise networks."
  }
  assert {
    condition     = alltrue([for key, vm in local.vms : openstack_networking_port_v2.lab[key].network_id == openstack_networking_network_v2.group[vm.team].id]) && openstack_networking_port_v2.lab["alpha/1"].network_id != openstack_networking_port_v2.lab["beta/1"].network_id
    error_message = "VMs must use their own group network, separate from the other group."
  }
  assert {
    condition     = alltrue([for key, vm in local.vms : length(openstack_compute_instance_v2.vm[key].network) == 2])
    error_message = "Every VM needs both an access and an exercise NIC."
  }
  assert {
    condition     = length(openstack_networking_secgroup_rule_v2.group) == 16 && alltrue([for key, rule in openstack_networking_secgroup_rule_v2.group : rule.remote_group_id == rule.security_group_id && (rule.protocol != "tcp" || (rule.port_range_min == 22 && rule.port_range_max == 22))])
    error_message = "SSH/ICMP rules must reference only their own group."
  }
  assert {
    condition     = output.team_vms["alpha"].vms["1"].lab_ip == "10.77.0.11" && output.team_vms["alpha"].vms["2"].lab_ip == "10.77.0.12" && length(output.team_vms["alpha"].vms) == 2
    error_message = "The inventory must include distinct addresses for both group VMs."
  }
  assert {
    condition     = alltrue([for key, subnet in openstack_networking_subnet_v2.group : subnet.no_gateway && subnet.ip_version == 4])
    error_message = "Exercise networks must not install a default gateway."
  }
  assert {
    condition     = alltrue([for key, account in output.user_accounts : account.port == 22 && account.protocol == "ssh" && startswith(account.username, "u")])
    error_message = "Account outputs must expose actual Linux SSH accounts."
  }
}
run "empty_roster" {
  command = plan
  variables { users = {} }
  assert {
    condition     = length(openstack_compute_instance_v2.vm) == 0 && length(openstack_networking_network_v2.group) == 0
    error_message = "Empty roster must not create resources."
  }
}
run "invalid_count" {
  command = plan
  variables { vms_per_group = 1 }
  expect_failures = [var.vms_per_group]
}
run "fractional_count" {
  command = plan
  variables { vms_per_group = 2.5 }
  expect_failures = [var.vms_per_group]
}
run "excessive_count" {
  command = plan
  variables { vms_per_group = 9 }
  expect_failures = [var.vms_per_group]
}
run "colliding_account_names" {
  command = plan
  variables {
    users = { alpha = [{ email = "alice@example.test" }, { email = "alice@other.test" }] }
  }
  expect_failures = [var.users]
}
run "group_names_with_spaces" {
  command = plan
  variables {
    users = { "Group 1" = [{ email = "alice@example.test" }] }
  }
  assert {
    condition     = length(openstack_compute_instance_v2.vm) == 2
    error_message = "Platform group names containing spaces must be supported."
  }
}
