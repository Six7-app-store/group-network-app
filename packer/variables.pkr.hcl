############################
# PLATFORM-Variablen (vom AppStore gesetzt)
############################

variable "image_name" {
  type        = string
  description = "Glance-Image-Name â€” vom Worker zur Build-Zeit gesetzt. @platform:internal"
  default     = "my-app-vX"
}

variable "networks" {
  type        = list(string)
  description = "@openstack:network:id:list"
  default     = []
}

variable "security_groups" {
  type        = list(string)
  description = "@openstack:security_group:id:list"
  default     = []
}
