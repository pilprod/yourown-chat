# Vendor chart values

This directory contains the readable, product-owned Helm values consumed by
the `app-gcp` vendor chart bundle adapter. Each release input names one file
under `helm/vendor/<bundle>/` and pins its exact SHA-256.

These files contain configuration and immutable image references only. Secrets
must stay in the platform secret plane and be mounted by name; do not place
credentials, generated Secret manifests, or encoded secret material here.
