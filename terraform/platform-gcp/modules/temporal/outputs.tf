output "release_name" { value = one(helm_release.this[*].name) }
