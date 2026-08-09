output "database_names" { value = one(module.databases[*].database_names) }
output "password_secret_id" { value = one(module.databases[*].password_secret_id) }
output "results_bucket_name" { value = one(module.results[*].name) }
output "release_name" { value = one(helm_release.this[*].name) }
