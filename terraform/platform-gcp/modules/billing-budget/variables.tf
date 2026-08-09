variable "billing_account_id" {
  type        = string
  description = "Cloud Billing account monitored by the monthly budget."
}

variable "project_number" {
  type        = string
  description = "Numeric GCP project number whose usage is included in the budget."
}

variable "display_name" {
  type        = string
  description = "Human-readable budget name."
  default     = "YourOwn.Chat monthly USD budget"
}

variable "currency_code" {
  type        = string
  description = "Billing account currency."
  default     = "USD"
}

variable "monthly_units" {
  type        = number
  description = "Whole currency units in the monthly budget."
  default     = 100
}

variable "actual_thresholds" {
  type        = set(number)
  description = "Actual-spend alert thresholds expressed as fractions of the budget."
  default     = [0.5, 0.75, 0.9, 1.0]
}

variable "forecast_thresholds" {
  type        = set(number)
  description = "Forecasted-spend alert thresholds expressed as fractions of the budget."
  default     = [1.0]
}
