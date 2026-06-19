variable "participant_name" {
  description = "Your participant name (lowercase, no spaces)"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "admin_password" {
  description = "Password used by the DB cloud-init bootstrap"
  type        = string
  sensitive   = true
}
