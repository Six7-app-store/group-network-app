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
  description = "Ubuntu image supplied by Worker @platform:internal"
  type        = string
}
variable "network_uuid" {
  description = "Access network in your project @openstack:network:id"
  type        = string
}
variable "shared_secgroup_id" {
  description = "Access security group allowing SSH from authorized clients @openstack:security_group:id"
  type        = string
}
variable "flavor_name" {
  description = "VM size @openstack:flavor:name"
  type        = string
  default     = "gp1.small"
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
