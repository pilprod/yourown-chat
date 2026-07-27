resource "google_billing_budget" "monthly" {
  billing_account = var.billing_account_id
  display_name    = var.display_name
  ownership_scope = "BILLING_ACCOUNT"

  lifecycle {
    prevent_destroy = true
  }

  budget_filter {
    calendar_period        = "MONTH"
    credit_types_treatment = "INCLUDE_ALL_CREDITS"
  }

  amount {
    specified_amount {
      currency_code = var.currency_code
      units         = tostring(var.monthly_units)
    }
  }

  dynamic "threshold_rules" {
    for_each = var.actual_thresholds
    content {
      threshold_percent = threshold_rules.value
      spend_basis       = "CURRENT_SPEND"
    }
  }

  dynamic "threshold_rules" {
    for_each = var.forecast_thresholds
    content {
      threshold_percent = threshold_rules.value
      spend_basis       = "FORECASTED_SPEND"
    }
  }

  # With no custom all_updates_rule, threshold emails use Google's default
  # recipients: human Billing Account Administrators and Billing Account Users.
}
