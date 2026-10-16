variable "users" {
  description = "Per-team roster @platform:internal"
  type        = map(list(object({ email = string })))
  default     = {}
  validation {
    condition     = alltrue([for team, members in var.users : length(members) > 0 && can(regex("^[A-Za-z0-9 _-]{1,48}$", team))])
    error_message = "Groups require members and a name of 1-48 letters, digits, spaces, underscores or hyphens."
  }
  validation {
    condition = alltrue([for team, members in var.users :
      length(distinct([for member in members : lower(replace(split("@", member.email)[0], "/[^a-zA-Z0-9]/", "-"))])) == length(members)
      && alltrue([for member in members : can(regex("^[A-Za-z0-9][A-Za-z0-9._+-]*@[A-Za-z0-9.-]+$", member.email))])
    ])
    error_message = "Use valid email addresses and distinct normalized email local parts per group for the platform account contract."
  }
}
variable "image_name" {
  description = "Ubuntu cloud image @openstack:image:name"
  type        = string
  default     = "Ubuntu 24.04"
}
variable "network_uuid" {
  description = "Primary access network (legacy fallback) @openstack:network:id"
  type        = string
  default     = ""
}
variable "ip_mode" {
  description = "Adressfamilie: ipv4, ipv6 oder dual"
  type        = string
  default     = "ipv6"
  validation {
    condition     = contains(["ipv4", "ipv6", "dual"], var.ip_mode)
    error_message = "ip_mode must be ipv4, ipv6 or dual."
  }
}
variable "network_v4_uuid" {
  description = "Routed IPv4 access network for ipv4/dual @openstack:network:id"
  type        = string
  default     = ""
}
variable "network_v6_uuid" {
  description = "IPv6 access network for ipv6/dual @openstack:network:id"
  type        = string
  default     = ""
}
variable "shared_secgroup_id" {
  description = "Access security group allowing SSH from authorized clients @openstack:security_group:id"
  type        = string
}
variable "flavor" {
  description = "VM size @openstack:flavor"
  type        = string
  default     = "gp1.small"
  validation {
    condition     = contains(["gp1.small", "gp1.medium", "gp1.large"], var.flavor)
    error_message = "flavor must be gp1.small, gp1.medium or gp1.large."
  }
}
variable "disk_size_gb" {
  description = "System disk in GB (0 = flavor default)"
  type        = number
  default     = 0
  validation {
    condition     = var.disk_size_gb >= 0 && var.disk_size_gb <= 200
    error_message = "disk_size_gb must be between 0 and 200."
  }
  validation {
    condition     = (var.disk_size_gb == 0 || var.disk_size_gb >= 10) && floor(var.disk_size_gb) == var.disk_size_gb
    error_message = "disk_size_gb must be 0 or an integer of at least 10."
  }
}
variable "app_name" {
  description = "Resource name prefix"
  type        = string
  default     = "group-network"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,31}$", var.app_name))
    error_message = "Use a lowercase resource prefix, maximum 32 characters."
  }
}
variable "vms_per_group" {
  description = "Number of exercise VMs per group (2-8)"
  type        = number
  default     = 2
  validation {
    condition     = var.vms_per_group >= 2 && var.vms_per_group <= 8 && floor(var.vms_per_group) == var.vms_per_group
    error_message = "Choose an integer between 2 and 8."
  }
}
