terraform {
  required_version = ">= 1.9, < 2.0"
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 1.53"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}
provider "openstack" { cloud = "openstack" }
locals {
  teams = toset(keys(var.users))
  vms = merge({}, [for team in local.teams : {
    for index in range(var.vms_per_group) : "${team}/${index + 1}" => { team = team, index = index + 1 }
  }]...)
  users_map = merge({}, [for team, members in var.users : {
    for member in members : "${team}/${member.email}" => {
      team     = team
      email    = member.email
      username = "u${substr(sha256(member.email), 0, 20)}"
    }
  }]...)
  rules = merge({}, [for team in local.teams : {
    for pair in setproduct(["ingress", "egress"], ["IPv4", "IPv6"], ["tcp", "icmp"]) : "${team}/${join("/", pair)}" => {
      team      = team
      direction = pair[0]
      ethertype = pair[1]
      protocol  = pair[2] == "icmp" && pair[1] == "IPv6" ? "ipv6-icmp" : pair[2]
      ssh       = pair[2] == "tcp"
    }
  }]...)
}
data "openstack_images_image_v2" "image" {
  name        = var.image_name
  most_recent = true
}
resource "random_password" "user_passwords" {
  for_each = local.users_map
  length   = 20
  special  = false
}
# No router between the separate group networks.
resource "openstack_networking_network_v2" "group" {
  for_each       = local.teams
  name           = "${var.app_name}-${each.key}-lab"
  admin_state_up = true
}
resource "openstack_networking_subnet_v2" "group" {
  for_each    = local.teams
  name        = "${var.app_name}-${each.key}-lab-v4"
  network_id  = openstack_networking_network_v2.group[each.key].id
  cidr        = "10.77.0.0/24"
  ip_version  = 4
  enable_dhcp = true
  no_gateway  = true
}
resource "openstack_networking_secgroup_v2" "group" {
  for_each             = local.teams
  name                 = "${var.app_name}-${each.key}-lab"
  description          = "Group-local SSH and ICMP only"
  delete_default_rules = true
}
resource "openstack_networking_secgroup_rule_v2" "group" {
  for_each          = local.rules
  security_group_id = openstack_networking_secgroup_v2.group[each.value.team].id
  remote_group_id   = openstack_networking_secgroup_v2.group[each.value.team].id
  direction         = each.value.direction
  ethertype         = each.value.ethertype
  protocol          = each.value.protocol
  port_range_min    = each.value.ssh ? 22 : null
  port_range_max    = each.value.ssh ? 22 : null
}
resource "openstack_networking_port_v2" "access" {
  for_each           = local.vms
  name               = "${var.app_name}-${each.value.team}-${each.value.index}-access"
  network_id         = var.network_uuid
  security_group_ids = [var.shared_secgroup_id]
}
resource "openstack_networking_port_v2" "lab" {
  for_each           = local.vms
  name               = "${var.app_name}-${each.value.team}-${each.value.index}-lab"
  network_id         = openstack_networking_network_v2.group[each.value.team].id
  security_group_ids = [openstack_networking_secgroup_v2.group[each.value.team].id]
  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.group[each.value.team].id
    ip_address = cidrhost(openstack_networking_subnet_v2.group[each.value.team].cidr, each.value.index + 10)
  }
}
resource "openstack_compute_instance_v2" "vm" {
  for_each    = local.vms
  name        = "${var.app_name}-${each.value.team}-${each.value.index}"
  image_id    = data.openstack_images_image_v2.image.id
  flavor_name = var.flavor_name
  network { port = openstack_networking_port_v2.access[each.key].id }
  network { port = openstack_networking_port_v2.lab[each.key].id }
  user_data = templatefile("${path.module}/user-data.yaml.tpl", {
    lab_mac = openstack_networking_port_v2.lab[each.key].mac_address
    lab_ip  = cidrhost(openstack_networking_subnet_v2.group[each.value.team].cidr, each.value.index + 10)
    team_users = [for uid, user in local.users_map : {
      username = user.username
      password = random_password.user_passwords[uid].result
    } if user.team == each.value.team]
  })
  metadata   = { team = each.value.team, app = var.app_name }
  depends_on = [openstack_networking_secgroup_rule_v2.group]
  timeouts {
    create = "15m"
    delete = "15m"
  }
}
