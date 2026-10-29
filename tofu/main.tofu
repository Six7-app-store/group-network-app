terraform {
  required_version = ">= 1.13.0, < 2.0"
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}
provider "openstack" { cloud = "openstack" }
locals {
  ipv4                 = var.ip_mode != "ipv6"
  ipv6                 = var.ip_mode != "ipv4"
  dual                 = var.ip_mode == "dual"
  ethertypes           = var.ip_mode == "dual" ? ["IPv4", "IPv6"] : (var.ip_mode == "ipv4" ? ["IPv4"] : ["IPv6"])
  primary_network_uuid = (var.ip_mode == "ipv4" ? var.network_v4_uuid : var.network_v6_uuid) != "" ? (var.ip_mode == "ipv4" ? var.network_v4_uuid : var.network_v6_uuid) : var.network_uuid
  primary_network_id   = local.primary_network_uuid != "" ? local.primary_network_uuid : try(data.openstack_networking_network_v2.access[0].id, "missing-network")
  secondary_network_id = var.network_v4_uuid != "" ? var.network_v4_uuid : try(data.openstack_networking_network_v2.access_v4[0].id, "missing-network")
  automatic_access_sg  = var.shared_secgroup_id == "" && length(local.teams) > 0
  access_secgroup_ids  = var.shared_secgroup_id != "" ? [var.shared_secgroup_id] : [for sg in openstack_networking_secgroup_v2.access : sg.id]
  # Platform rosters may include groups that have no members yet.
  teams = toset([for team, members in var.users : team if length(members) > 0])
  # Preserve display names and state keys; use bounded, collision-resistant
  # ASCII names only for OpenStack resources.
  team_resource_names = {
    for team in local.teams : team => "${substr(trim(replace(lower(team), "/[^a-z0-9_-]+/", "-"), "-"), 0, 32)}-${substr(sha256(team), 0, 8)}"
  }
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
    for pair in setproduct(["ingress", "egress"], local.ethertypes, ["tcp", "icmp"]) : "${team}/${join("/", pair)}" => {
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
# Lookup runs inside the task's authenticated cloud/project visibility.
# Operators may override with an explicit network UUID or another network name.
data "openstack_networking_network_v2" "access" {
  count = length(local.teams) > 0 && local.primary_network_uuid == "" ? 1 : 0
  name  = var.ip_mode == "ipv4" ? var.network_v4_name : var.network_v6_name
}
data "openstack_networking_network_v2" "access_v4" {
  count = local.dual && length(local.teams) > 0 && var.network_v4_uuid == "" ? 1 : 0
  name  = var.network_v4_name
}
data "openstack_networking_network_v2" "access_v4_details" {
  count      = local.dual && length(local.teams) > 0 ? 1 : 0
  network_id = local.secondary_network_id
}
resource "openstack_networking_secgroup_v2" "access" {
  count                = local.automatic_access_sg ? 1 : 0
  name                 = "${var.app_name}-access"
  description          = "App-owned SSH access (${var.ip_mode})"
  delete_default_rules = true
}
resource "openstack_networking_secgroup_rule_v2" "access_ssh" {
  for_each          = local.automatic_access_sg ? toset(local.ethertypes) : toset([])
  security_group_id = openstack_networking_secgroup_v2.access[0].id
  direction         = "ingress"
  ethertype         = each.key
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = each.key == "IPv4" ? var.ssh_allowed_cidr_v4 : var.ssh_allowed_cidr_v6
}
resource "openstack_networking_secgroup_rule_v2" "access_icmp" {
  for_each          = local.automatic_access_sg ? toset(local.ethertypes) : toset([])
  security_group_id = openstack_networking_secgroup_v2.access[0].id
  direction         = "ingress"
  ethertype         = each.key
  protocol          = each.key == "IPv4" ? "icmp" : "ipv6-icmp"
  remote_ip_prefix  = each.key == "IPv4" ? var.ssh_allowed_cidr_v4 : "::/0"
}
resource "openstack_networking_secgroup_rule_v2" "access_egress" {
  # IPv6 access networks may provide IPv4 NAT for apt/DNS as in Ubuntu-App.
  for_each          = local.automatic_access_sg ? toset(["IPv4", "IPv6"]) : toset([])
  security_group_id = openstack_networking_secgroup_v2.access[0].id
  direction         = "egress"
  ethertype         = each.key
  remote_ip_prefix  = each.key == "IPv4" ? "0.0.0.0/0" : "::/0"
}
resource "random_password" "user_passwords" {
  for_each = local.users_map
  length   = 20
  special  = false
}
# No router between the separate group networks.
resource "openstack_networking_network_v2" "group" {
  for_each       = local.teams
  name           = "${var.app_name}-${local.team_resource_names[each.key]}-lab"
  admin_state_up = true
}
resource "openstack_networking_subnet_v2" "group" {
  for_each    = local.ipv4 ? local.teams : toset([])
  name        = "${var.app_name}-${local.team_resource_names[each.key]}-lab-v4"
  network_id  = openstack_networking_network_v2.group[each.key].id
  cidr        = "10.77.0.0/24"
  ip_version  = 4
  enable_dhcp = false
  no_gateway  = true
}
resource "openstack_networking_subnet_v2" "group_v6" {
  for_each    = local.ipv6 ? local.teams : toset([])
  name        = "${var.app_name}-${local.team_resource_names[each.key]}-lab-v6"
  network_id  = openstack_networking_network_v2.group[each.key].id
  cidr        = "fd77:77::/64"
  ip_version  = 6
  enable_dhcp = false
  no_gateway  = true
}
resource "openstack_networking_secgroup_v2" "group" {
  for_each             = local.teams
  name                 = "${var.app_name}-${local.team_resource_names[each.key]}-lab"
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
# IPv6 neighbour discovery uses link-local/multicast sources, which a
# remote-group-only rule cannot reliably match. No TCP is opened here.
resource "openstack_networking_secgroup_rule_v2" "ndp" {
  for_each          = local.ipv6 ? { for pair in setproduct(local.teams, ["ingress", "egress"], ["135", "136"]) : join("/", pair) => pair } : {}
  security_group_id = openstack_networking_secgroup_v2.group[each.value[0]].id
  direction         = each.value[1]
  ethertype         = "IPv6"
  protocol          = "ipv6-icmp"
  port_range_min    = tonumber(each.value[2])
  port_range_max    = 0
  remote_ip_prefix  = "::/0"
}
resource "openstack_networking_port_v2" "access" {
  for_each           = local.vms
  name               = "${var.app_name}-${local.team_resource_names[each.value.team]}-${each.value.index}-access"
  network_id         = local.primary_network_id
  security_group_ids = local.access_secgroup_ids
}
resource "openstack_networking_port_v2" "access_v4" {
  for_each           = local.dual ? local.vms : {}
  name               = "${var.app_name}-${local.team_resource_names[each.value.team]}-${each.value.index}-access-v4"
  network_id         = local.secondary_network_id
  security_group_ids = local.access_secgroup_ids
  fixed_ip {
    subnet_id = data.openstack_networking_subnet_v2.access_v4[0].id
  }
}
locals {
  secondary_ipv4 = {
    for key, port in openstack_networking_port_v2.access_v4 : key => one([for ip in port.all_fixed_ips : ip if !strcontains(ip, ":")])
  }
}
data "openstack_networking_subnet_v2" "access_v4" {
  count      = local.dual && length(local.teams) > 0 ? 1 : 0
  network_id = local.secondary_network_id
  ip_version = 4
}
resource "openstack_networking_port_v2" "lab" {
  for_each           = local.vms
  name               = "${var.app_name}-${local.team_resource_names[each.value.team]}-${each.value.index}-lab"
  network_id         = openstack_networking_network_v2.group[each.value.team].id
  security_group_ids = [openstack_networking_secgroup_v2.group[each.value.team].id]
  dynamic "fixed_ip" {
    for_each = local.ipv4 ? [1] : []
    content {
      subnet_id  = openstack_networking_subnet_v2.group[each.value.team].id
      ip_address = cidrhost(openstack_networking_subnet_v2.group[each.value.team].cidr, each.value.index + 10)
    }
  }
  dynamic "fixed_ip" {
    for_each = local.ipv6 ? [1] : []
    content {
      subnet_id  = openstack_networking_subnet_v2.group_v6[each.value.team].id
      ip_address = cidrhost(openstack_networking_subnet_v2.group_v6[each.value.team].cidr, each.value.index + 10)
    }
  }
}
resource "openstack_compute_instance_v2" "vm" {
  for_each    = local.vms
  name        = "${var.app_name}-${local.team_resource_names[each.value.team]}-${each.value.index}"
  image_id    = var.disk_size_gb > 0 ? null : data.openstack_images_image_v2.image.id
  flavor_name = var.flavor
  dynamic "block_device" {
    for_each = var.disk_size_gb > 0 ? [1] : []
    content {
      uuid                  = data.openstack_images_image_v2.image.id
      source_type           = "image"
      destination_type      = "volume"
      volume_size           = var.disk_size_gb
      boot_index            = 0
      delete_on_termination = true
    }
  }
  network { port = openstack_networking_port_v2.access[each.key].id }
  network { port = openstack_networking_port_v2.lab[each.key].id }
  user_data = templatefile("${path.module}/user-data.yaml.tpl", {
    lab_mac = openstack_networking_port_v2.lab[each.key].mac_address
    lab_mtu = coalesce(openstack_networking_network_v2.group[each.value.team].mtu, 0)
    lab_addresses = concat(
      local.ipv4 ? ["${cidrhost(openstack_networking_subnet_v2.group[each.value.team].cidr, each.value.index + 10)}/24"] : [],
      local.ipv6 ? ["${cidrhost(openstack_networking_subnet_v2.group_v6[each.value.team].cidr, each.value.index + 10)}/64"] : []
    )
    secondary_mac     = local.dual ? openstack_networking_port_v2.access_v4[each.key].mac_address : ""
    secondary_mtu     = local.dual ? coalesce(data.openstack_networking_network_v2.access_v4_details[0].mtu, 0) : 0
    secondary_address = local.dual ? "${local.secondary_ipv4[each.key]}/${split("/", data.openstack_networking_subnet_v2.access_v4[0].cidr)[1]}" : ""
    secondary_cidr    = local.dual ? data.openstack_networking_subnet_v2.access_v4[0].cidr : ""
    secondary_gateway = local.dual ? coalesce(data.openstack_networking_subnet_v2.access_v4[0].gateway_ip, "none") : ""
    team_users = [for uid, user in local.users_map : {
      username = user.username
      password = random_password.user_passwords[uid].result
    } if user.team == each.value.team]
  })
  metadata   = { team = each.value.team, app = var.app_name }
  depends_on = [openstack_networking_secgroup_rule_v2.group, openstack_networking_secgroup_rule_v2.ndp, openstack_networking_secgroup_rule_v2.access_ssh, openstack_networking_secgroup_rule_v2.access_icmp, openstack_networking_secgroup_rule_v2.access_egress]
  lifecycle {
    precondition {
      condition     = local.primary_network_id != "missing-network"
      error_message = "Set the access network for the selected ip_mode (or network_uuid)."
    }
    precondition {
      condition     = !local.dual || (local.secondary_network_id != "missing-network" && local.secondary_network_id != local.primary_network_id)
      error_message = "dual requires a separate routed IPv4 access network alongside the IPv6 primary network. Select UUIDs or unique network names."
    }
  }
  timeouts {
    create = "15m"
    delete = "15m"
  }
}
resource "openstack_compute_interface_attach_v2" "access_v4" {
  for_each    = local.dual ? local.vms : {}
  instance_id = openstack_compute_instance_v2.vm[each.key].id
  port_id     = openstack_networking_port_v2.access_v4[each.key].id
}
