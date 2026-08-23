# identity release wrapper (fixture)

Minimal service release wrapper used by `helm/test/platform-release.test.sh`.
A real wrapper lives in the owning service repository, pins exact published
platform profile versions from the platform OCI registry and commits
`Chart.lock`.
