## AppD Variables ##
variable "appd_account_name" {
  type = string
}

variable "appd_otel_api_key" {
  type = string
}

variable "appd_account_key" {
  type = string
}

variable "appd_account_username" {
  type = string
}

variable "appd_account_password" {
  type = string
}

## Demo App Variables ##
variable "demo_app_url" {
  type = string
}

## IWO Collector Variables ##
variable "iwo_cluster_name" {
  type = string
}

variable "iwo_chart_url" {
  type = string
}

variable "iwo_server_version" {
  type = string
}

variable "iwo_collector_image_version" {
  type = string
}

variable "dc_image_version" {
  type = string
}

## Secure Cloud Analytics ##
variable "sca_chart_url" {
  type = string
}

variable "sca_service_key" {
  type = string
}
