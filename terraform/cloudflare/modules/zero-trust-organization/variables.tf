variable "account_id" {
  type        = string
  description = "Cloudflare account ID owning the existing Zero Trust organization."
}

variable "team_name" {
  type        = string
  description = "Zero Trust team name and cloudflareaccess.com subdomain label."
}
