// Command adopt-kagent-substrate-secrets performs the one-time, fixed-contract
// migration of an already-running Substrate installation's native Kubernetes
// Secrets into the empty Secret Manager containers created by app-gcp.
//
// Secret bytes are held only in process memory and child-process pipes. This
// command intentionally has no file input, file output, arbitrary Secret-name
// flags, or diagnostic path which includes command output.
package main

import (
	"bytes"
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	payloadSchema = "yourown.chat/native-secret-envelope/v1"
	fieldManager  = "yourown-chat-secret-bootstrap"
	commandLimit  = 2 << 20
)

type sourceSpec struct {
	logical    string
	secretID   string
	namespace  string
	kubernetes string
	keys       []string
}

var sourceContract = []sourceSpec{
	{logical: "postgres", secretID: "substrate-database-url", namespace: "ate-system", kubernetes: "substrate-cloud-sql", keys: []string{"connection-string"}},
	{logical: "api_tls", secretID: "substrate-ate-api-tls", namespace: "ate-system", kubernetes: "substrate-ate-api-tls", keys: []string{"server-credential-bundle.pem", "client-ca.pem"}},
	{logical: "controller_tls", secretID: "substrate-ate-controller-tls", namespace: "ate-system", kubernetes: "substrate-ate-controller-tls", keys: []string{"client-credential-bundle.pem", "server-ca.pem"}},
	{logical: "egress_gateway_tls", secretID: "substrate-atenet-egress-server-tls", namespace: "ate-system", kubernetes: "substrate-atenet-egress-server-tls", keys: []string{"server-credential-bundle.pem", "server-ca.pem"}},
	{logical: "egress_authorizer_tls", secretID: "substrate-atenet-egress-client-tls", namespace: "ate-system", kubernetes: "substrate-atenet-egress-client-tls", keys: []string{"client-credential-bundle.pem", "server-ca.pem"}},
	{logical: "actor_id_jwt_pool", secretID: "substrate-actor-id-jwt-pool", namespace: "ate-system", kubernetes: "actor-id-jwt-pool", keys: []string{"pool"}},
	{logical: "actor_id_ca_pool", secretID: "substrate-actor-id-ca-pool", namespace: "ate-system", kubernetes: "actor-id-ca-pool", keys: []string{"pool"}},
	{logical: "kagent_client_tls", secretID: "kagent-ate-client-tls", namespace: "kagent-system", kubernetes: "kagent-ate-client-tls", keys: []string{"client-credential-bundle.pem", "server-ca.pem"}},
	{logical: "kagent_dev_client_tls", secretID: "kagent-dev-ate-client-tls", namespace: "kagent-dev", kubernetes: "kagent-dev-ate-client-tls", keys: []string{"client-credential-bundle.pem", "server-ca.pem"}},
}

var derivedContract = sourceSpec{
	logical: "actor_id_ca_certs", namespace: "ate-system", kubernetes: "actor-id-ca-certs", keys: []string{"ca.crt"},
}

type kubernetesSecret struct {
	APIVersion string `json:"apiVersion"`
	Kind       string `json:"kind"`
	Metadata   struct {
		Name            string            `json:"name"`
		Namespace       string            `json:"namespace"`
		UID             string            `json:"uid"`
		ResourceVersion string            `json:"resourceVersion"`
		Labels          map[string]string `json:"labels"`
		Annotations     map[string]string `json:"annotations"`
	} `json:"metadata"`
	Type      string            `json:"type"`
	Data      map[string][]byte `json:"data"`
	Immutable *bool             `json:"immutable"`
}

type secretVersion struct {
	Name  string `json:"name"`
	State string `json:"state"`
}

type secretManagerSnapshot struct {
	versions map[string][]secretVersion
}

type envelope struct {
	Schema string            `json:"schema"`
	Data   map[string]string `json:"data"`
}

type boundedBuffer struct {
	buffer    bytes.Buffer
	limit     int
	truncated bool
}

func (w *boundedBuffer) Write(p []byte) (int, error) {
	written := len(p)
	remaining := w.limit - w.buffer.Len()
	if remaining > 0 {
		if remaining > len(p) {
			remaining = len(p)
		}
		_, _ = w.buffer.Write(p[:remaining])
	}
	if len(p) > remaining {
		w.truncated = true
	}
	return written, nil
}

type adopter struct {
	project string
	context string
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "kagent/Substrate existing Secret adoption failed: %s\n", err)
		os.Exit(1)
	}
}

func run() error {
	flags := flag.NewFlagSet("adopt-kagent-substrate-secrets", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	project := flags.String("project", "", "Google Cloud project ID")
	kubeContext := flags.String("context", "", "explicit kubectl context")
	if err := flags.Parse(os.Args[1:]); err != nil || flags.NArg() != 0 {
		return errors.New("expected only --project PROJECT and --context KUBE_CONTEXT")
	}
	if !regexp.MustCompile(`^[a-z][a-z0-9-]{4,28}[a-z0-9]$`).MatchString(*project) {
		return errors.New("--project is required and must be a valid project ID")
	}
	if *kubeContext == "" || strings.IndexFunc(*kubeContext, func(r rune) bool { return r < 0x20 || r == 0x7f }) >= 0 {
		return errors.New("--context is required and must not contain control characters")
	}
	if _, err := exec.LookPath("kubectl"); err != nil {
		return errors.New("required command is unavailable: kubectl")
	}
	if _, err := exec.LookPath("gcloud"); err != nil {
		return errors.New("required command is unavailable: gcloud")
	}

	a := &adopter{project: *project, context: *kubeContext}
	return a.adopt()
}

func runCommand(label string, stdin []byte, name string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, name, args...)
	command.Env = safeCommandEnvironment()
	if stdin != nil {
		command.Stdin = bytes.NewReader(stdin)
	}
	stdout := &boundedBuffer{limit: commandLimit}
	stderr := &boundedBuffer{limit: 16 << 10}
	command.Stdout = stdout
	command.Stderr = stderr
	if err := command.Run(); err != nil {
		return nil, fmt.Errorf("%s", label)
	}
	if stdout.truncated || stderr.truncated {
		return nil, fmt.Errorf("%s exceeded the bounded command-output limit", label)
	}
	return append([]byte(nil), stdout.buffer.Bytes()...), nil
}

func safeCommandEnvironment() []string {
	blocked := map[string]struct{}{
		"CLOUDSDK_CORE_DISABLE_PROMPTS": {},
		"CLOUDSDK_CORE_LOG_HTTP":        {},
		"CLOUDSDK_CORE_VERBOSITY":       {},
	}
	environment := make([]string, 0, len(os.Environ())+3)
	for _, item := range os.Environ() {
		key, _, _ := strings.Cut(item, "=")
		if _, remove := blocked[key]; remove {
			continue
		}
		environment = append(environment, item)
	}
	return append(environment,
		"CLOUDSDK_CORE_DISABLE_PROMPTS=1",
		"CLOUDSDK_CORE_LOG_HTTP=false",
		"CLOUDSDK_CORE_VERBOSITY=error",
	)
}

func (a *adopter) adopt() error {
	if err := a.checkKubernetesAccess(); err != nil {
		return err
	}

	secrets := make(map[string]*kubernetesSecret, len(sourceContract)+1)
	data := make(map[string]map[string][]byte, len(sourceContract)+1)
	for _, spec := range kubernetesContract() {
		secret, err := a.getKubernetesSecret(spec)
		if err != nil {
			return err
		}
		secrets[spec.logical] = secret
		data[spec.logical] = cloneData(secret.Data)
	}

	derivedCA, err := validateMaterializedContract(data)
	if err != nil {
		return err
	}
	if !bytes.Equal(data[derivedContract.logical]["ca.crt"], derivedCA) {
		return errors.New("existing ate-system/actor-id-ca-certs does not match actor-id-ca-pool")
	}

	for _, spec := range sourceContract {
		if err := a.ensureSecretContainer(spec.secretID); err != nil {
			return err
		}
	}
	postgresVersions, err := a.listSecretVersions(sourceContract[0])
	if err != nil {
		return err
	}
	postgresVersion, err := a.latestEnabledVersion(sourceContract[0], postgresVersions)
	if err != nil {
		return err
	}
	postgres, err := a.accessSecretVersion(sourceContract[0], a.versionNumber(sourceContract[0], postgresVersion.Name))
	if err != nil {
		return err
	}
	if err := validatePostgresURI(postgres); err != nil {
		return err
	}
	if !bytes.Equal(postgres, data["postgres"]["connection-string"]) {
		return errors.New("existing Kubernetes PostgreSQL value differs from substrate-database-url latest")
	}

	payloads := make(map[string][]byte, len(sourceContract)-1)
	pending := make([]sourceSpec, 0, len(sourceContract)-1)
	for _, spec := range sourceContract[1:] {
		payload, err := buildEnvelope(spec, data[spec.logical])
		if err != nil {
			return err
		}
		payloads[spec.logical] = payload
		versions, err := a.listSecretVersions(spec)
		if err != nil {
			return err
		}
		switch len(versions) {
		case 0:
			pending = append(pending, spec)
		case 1:
			if versions[0].State != "ENABLED" {
				return fmt.Errorf("Secret Manager container %s has a non-enabled pre-existing version", spec.secretID)
			}
			current, err := a.accessSecretVersion(spec, a.versionNumber(spec, versions[0].Name))
			if err != nil {
				return err
			}
			if err := compareEnvelope(spec, data[spec.logical], current); err != nil {
				return err
			}
		default:
			return fmt.Errorf("Secret Manager container %s is not an empty-or-single-exact adoption target", spec.secretID)
		}
	}

	// The validation above can be long enough for a live controller or operator
	// to change one of the sources. Re-read the complete fixed set immediately
	// before the first possible Secret Manager write and require the original
	// UID, resourceVersion, identity and exact data.
	if err := a.revalidateKubernetesSnapshot(secrets, data); err != nil {
		return err
	}

	for _, spec := range pending {
		versionName, err := a.addSecretVersion(spec, payloads[spec.logical])
		if err != nil {
			return err
		}
		readback, err := a.accessSecretVersion(spec, a.versionNumber(spec, versionName))
		if err != nil {
			return err
		}
		if !bytes.Equal(readback, payloads[spec.logical]) {
			return fmt.Errorf("new Secret Manager version differs from the validated envelope: %s", spec.secretID)
		}
		fmt.Printf("added Secret Manager version %s\n", versionName)
	}

	// Capture the exact nine-source Secret Manager state immediately before
	// Kubernetes reconciliation. PostgreSQL history must be unchanged since the
	// initial comparison; every adoption target must now be one exact enabled
	// envelope.
	managerSnapshot, err := a.captureSecretManagerSnapshot(data, postgresVersions)
	if err != nil {
		return err
	}

	for _, spec := range kubernetesContract() {
		if err := a.reconcileSecret(spec, secrets[spec.logical], data[spec.logical]); err != nil {
			return err
		}
	}
	for _, spec := range kubernetesContract() {
		verified, err := a.getKubernetesSecret(spec)
		if err != nil {
			return err
		}
		if verified.Metadata.UID != secrets[spec.logical].Metadata.UID || !equalData(verified.Data, data[spec.logical]) || !managedLabelsValid(verified.Metadata.Labels) {
			return fmt.Errorf("synchronized Secret verification failed: %s/%s", spec.namespace, spec.kubernetes)
		}
		secrets[spec.logical] = verified
	}
	// This is the cleanup gate: if PostgreSQL or any envelope changed while the
	// Kubernetes set was being reconciled, preserve every recovery annotation.
	if err := a.revalidateSecretManagerSnapshot(managerSnapshot, data); err != nil {
		return err
	}

	// Remove the client-side apply snapshot only after every version and every
	// exact Kubernetes value has been reconciled and read back successfully.
	for _, spec := range kubernetesContract() {
		if err := a.removeLastApplied(spec, secrets[spec.logical]); err != nil {
			return err
		}
	}
	for _, spec := range kubernetesContract() {
		verified, err := a.getKubernetesSecret(spec)
		if err != nil {
			return err
		}
		if verified.Metadata.UID != secrets[spec.logical].Metadata.UID || !equalData(verified.Data, data[spec.logical]) || !managedLabelsValid(verified.Metadata.Labels) {
			return fmt.Errorf("final Secret verification failed: %s/%s", spec.namespace, spec.kubernetes)
		}
		if _, exists := verified.Metadata.Annotations["kubectl.kubernetes.io/last-applied-configuration"]; exists {
			return fmt.Errorf("last-applied annotation remains on %s/%s", spec.namespace, spec.kubernetes)
		}
	}
	// A last full Secret Manager barrier prevents a drifted adoption from being
	// reported as successful. Cross-system atomicity still requires the
	// documented exclusive adoption window.
	if err := a.revalidateSecretManagerSnapshot(managerSnapshot, data); err != nil {
		return err
	}
	for _, spec := range kubernetesContract() {
		fmt.Printf("adopted Kubernetes Secret %s/%s\n", spec.namespace, spec.kubernetes)
	}
	return nil
}

func kubernetesContract() []sourceSpec {
	return append(append([]sourceSpec(nil), sourceContract...), derivedContract)
}

func (a *adopter) checkKubernetesAccess() error {
	for _, namespace := range []string{"ate-system", "kagent-system", "kagent-dev"} {
		if _, err := runCommand("namespace "+namespace+" is unavailable", nil, "kubectl", "--context="+a.context, "get", "namespace", namespace, "-o", "name"); err != nil {
			return err
		}
		for _, verb := range []string{"get", "patch"} {
			output, err := runCommand("cannot check Kubernetes Secret "+verb+" permission in "+namespace, nil, "kubectl", "--context="+a.context, "auth", "can-i", verb, "secrets", "-n", namespace)
			if err != nil || strings.TrimSpace(string(output)) != "yes" {
				return fmt.Errorf("context %s cannot %s Secrets in %s", a.context, verb, namespace)
			}
		}
	}
	return nil
}

func (a *adopter) getKubernetesSecret(spec sourceSpec) (*kubernetesSecret, error) {
	output, err := runCommand("Kubernetes Secret is unavailable: "+spec.namespace+"/"+spec.kubernetes, nil, "kubectl", "--context="+a.context, "-n", spec.namespace, "get", "secret", spec.kubernetes, "-o", "json")
	if err != nil {
		return nil, err
	}
	var secret kubernetesSecret
	if err := json.Unmarshal(output, &secret); err != nil {
		return nil, fmt.Errorf("Kubernetes Secret response is invalid: %s/%s", spec.namespace, spec.kubernetes)
	}
	if secret.APIVersion != "v1" || secret.Kind != "Secret" || secret.Metadata.Name != spec.kubernetes || secret.Metadata.Namespace != spec.namespace || secret.Metadata.UID == "" || secret.Metadata.ResourceVersion == "" {
		return nil, fmt.Errorf("Kubernetes Secret identity is invalid: %s/%s", spec.namespace, spec.kubernetes)
	}
	if secret.Type != "Opaque" || (secret.Immutable != nil && *secret.Immutable) {
		return nil, fmt.Errorf("Kubernetes Secret must be mutable Opaque: %s/%s", spec.namespace, spec.kubernetes)
	}
	if !exactKeys(secret.Data, spec.keys) {
		return nil, fmt.Errorf("Kubernetes Secret keys do not match the fixed contract: %s/%s", spec.namespace, spec.kubernetes)
	}
	for _, key := range spec.keys {
		if len(secret.Data[key]) == 0 {
			return nil, fmt.Errorf("Kubernetes Secret key is empty: %s/%s/%s", spec.namespace, spec.kubernetes, key)
		}
	}
	return &secret, nil
}

func (a *adopter) revalidateKubernetesSnapshot(expected map[string]*kubernetesSecret, data map[string]map[string][]byte) error {
	for _, spec := range kubernetesContract() {
		current, err := a.getKubernetesSecret(spec)
		if err != nil {
			return err
		}
		original := expected[spec.logical]
		if original == nil || current.Metadata.UID != original.Metadata.UID || current.Metadata.ResourceVersion != original.Metadata.ResourceVersion || !equalData(current.Data, data[spec.logical]) {
			return fmt.Errorf("Kubernetes Secret changed during pre-upload validation: %s/%s", spec.namespace, spec.kubernetes)
		}
	}
	return nil
}

func (a *adopter) ensureSecretContainer(secretID string) error {
	output, err := runCommand("Secret Manager container is unavailable: "+secretID, nil, "gcloud", "secrets", "describe", secretID, "--project="+a.project, "--format=value(name)")
	if err != nil || strings.TrimSpace(string(output)) == "" {
		return fmt.Errorf("Secret Manager container is unavailable: %s", secretID)
	}
	return nil
}

func (a *adopter) listSecretVersions(spec sourceSpec) ([]secretVersion, error) {
	output, err := runCommand("Secret Manager version metadata is unavailable: "+spec.secretID, nil, "gcloud", "secrets", "versions", "list", spec.secretID, "--project="+a.project, "--format=json(name,state)", "--sort-by=name")
	if err != nil {
		return nil, err
	}
	var versions []secretVersion
	if err := json.Unmarshal(output, &versions); err != nil {
		return nil, fmt.Errorf("Secret Manager version metadata is invalid: %s", spec.secretID)
	}
	seen := make(map[string]struct{}, len(versions))
	for _, version := range versions {
		number := a.versionNumber(spec, version.Name)
		if number == "" {
			return nil, fmt.Errorf("Secret Manager version identity is invalid: %s", spec.secretID)
		}
		if _, err := strconv.ParseUint(number, 10, 64); err != nil {
			return nil, fmt.Errorf("Secret Manager version identity is invalid: %s", spec.secretID)
		}
		if version.State == "" {
			return nil, fmt.Errorf("Secret Manager version state is missing: %s", spec.secretID)
		}
		if _, duplicate := seen[number]; duplicate {
			return nil, fmt.Errorf("Secret Manager version identity is duplicated: %s", spec.secretID)
		}
		seen[number] = struct{}{}
	}
	sort.Slice(versions, func(i, j int) bool {
		left, _ := strconv.ParseUint(a.versionNumber(spec, versions[i].Name), 10, 64)
		right, _ := strconv.ParseUint(a.versionNumber(spec, versions[j].Name), 10, 64)
		return left < right
	})
	return versions, nil
}

func (a *adopter) latestEnabledVersion(spec sourceSpec, versions []secretVersion) (secretVersion, error) {
	if len(versions) == 0 || versions[len(versions)-1].State != "ENABLED" {
		return secretVersion{}, fmt.Errorf("Secret Manager container %s has no enabled latest version", spec.secretID)
	}
	return versions[len(versions)-1], nil
}

func (a *adopter) captureSecretManagerSnapshot(data map[string]map[string][]byte, expectedPostgresVersions []secretVersion) (*secretManagerSnapshot, error) {
	snapshot := &secretManagerSnapshot{versions: make(map[string][]secretVersion, len(sourceContract))}
	for index, spec := range sourceContract {
		versions, err := a.listSecretVersions(spec)
		if err != nil {
			return nil, err
		}
		if index == 0 {
			if !equalSecretVersions(versions, expectedPostgresVersions) {
				return nil, fmt.Errorf("Secret Manager container %s changed during adoption", spec.secretID)
			}
			selected, err := a.latestEnabledVersion(spec, versions)
			if err != nil {
				return nil, err
			}
			current, err := a.accessSecretVersion(spec, a.versionNumber(spec, selected.Name))
			if err != nil {
				return nil, err
			}
			if err := validatePostgresURI(current); err != nil {
				return nil, err
			}
			if !bytes.Equal(current, data[spec.logical]["connection-string"]) {
				return nil, fmt.Errorf("Secret Manager PostgreSQL value changed during adoption: %s", spec.secretID)
			}
		} else {
			if len(versions) != 1 || versions[0].State != "ENABLED" {
				return nil, fmt.Errorf("Secret Manager container %s changed during adoption", spec.secretID)
			}
			current, err := a.accessSecretVersion(spec, a.versionNumber(spec, versions[0].Name))
			if err != nil {
				return nil, err
			}
			if err := compareEnvelope(spec, data[spec.logical], current); err != nil {
				return nil, err
			}
		}
		snapshot.versions[spec.logical] = cloneSecretVersions(versions)
	}
	return snapshot, nil
}

func (a *adopter) revalidateSecretManagerSnapshot(expected *secretManagerSnapshot, data map[string]map[string][]byte) error {
	if expected == nil || len(expected.versions) != len(sourceContract) {
		return errors.New("Secret Manager adoption snapshot is incomplete")
	}
	for index, spec := range sourceContract {
		versions, err := a.listSecretVersions(spec)
		if err != nil {
			return err
		}
		if !equalSecretVersions(versions, expected.versions[spec.logical]) {
			return fmt.Errorf("Secret Manager container %s changed during adoption", spec.secretID)
		}
		selected := versions[0]
		if index == 0 {
			selected, err = a.latestEnabledVersion(spec, versions)
			if err != nil {
				return err
			}
		}
		current, err := a.accessSecretVersion(spec, a.versionNumber(spec, selected.Name))
		if err != nil {
			return err
		}
		if index == 0 {
			if err := validatePostgresURI(current); err != nil {
				return err
			}
			if !bytes.Equal(current, data[spec.logical]["connection-string"]) {
				return fmt.Errorf("Secret Manager PostgreSQL value changed during adoption: %s", spec.secretID)
			}
		} else if err := compareEnvelope(spec, data[spec.logical], current); err != nil {
			return err
		}
	}
	return nil
}

func cloneSecretVersions(versions []secretVersion) []secretVersion {
	return append([]secretVersion(nil), versions...)
}

func equalSecretVersions(left, right []secretVersion) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

func (a *adopter) versionNumber(spec sourceSpec, name string) string {
	pattern := regexp.MustCompile(`^projects/(?:` + regexp.QuoteMeta(a.project) + `|[1-9][0-9]*)/secrets/` + regexp.QuoteMeta(spec.secretID) + `/versions/([1-9][0-9]*)$`)
	matches := pattern.FindStringSubmatch(name)
	if len(matches) != 2 {
		return ""
	}
	return matches[1]
}

func (a *adopter) accessSecretVersion(spec sourceSpec, version string) ([]byte, error) {
	if version == "" {
		return nil, fmt.Errorf("Secret Manager version identity is invalid: %s", spec.secretID)
	}
	output, err := runCommand("Secret Manager payload is unavailable: "+spec.secretID, nil, "gcloud", "secrets", "versions", "access", version, "--secret="+spec.secretID, "--project="+a.project)
	if err != nil {
		return nil, err
	}
	if len(output) == 0 || len(output) > 65536 {
		return nil, fmt.Errorf("Secret Manager payload size is invalid: %s", spec.secretID)
	}
	return output, nil
}

func (a *adopter) addSecretVersion(spec sourceSpec, payload []byte) (string, error) {
	output, err := runCommand("failed to add a Secret Manager version for "+spec.secretID, payload, "gcloud", "secrets", "versions", "add", spec.secretID, "--project="+a.project, "--data-file=-", "--format=value(name)")
	if err != nil {
		return "", err
	}
	name := strings.TrimSpace(string(output))
	if a.versionNumber(spec, name) == "" {
		return "", fmt.Errorf("Secret Manager returned no valid version identifier for %s", spec.secretID)
	}
	return name, nil
}

func (a *adopter) reconcileSecret(spec sourceSpec, existing *kubernetesSecret, data map[string][]byte) error {
	manifest := struct {
		APIVersion string `json:"apiVersion"`
		Kind       string `json:"kind"`
		Metadata   struct {
			Name            string            `json:"name"`
			Namespace       string            `json:"namespace"`
			UID             string            `json:"uid"`
			ResourceVersion string            `json:"resourceVersion"`
			Labels          map[string]string `json:"labels"`
		} `json:"metadata"`
		Type string            `json:"type"`
		Data map[string][]byte `json:"data"`
	}{APIVersion: "v1", Kind: "Secret", Type: "Opaque", Data: cloneData(data)}
	manifest.Metadata.Name = spec.kubernetes
	manifest.Metadata.Namespace = spec.namespace
	manifest.Metadata.UID = existing.Metadata.UID
	manifest.Metadata.ResourceVersion = existing.Metadata.ResourceVersion
	manifest.Metadata.Labels = map[string]string{
		"app.kubernetes.io/managed-by":          "yourown-chat-secret-bootstrap",
		"app.kubernetes.io/part-of":             "kagent-substrate-testbed",
		"platform.yourown.chat/secret-contract": "v1",
	}
	payload, err := json.Marshal(manifest)
	if err != nil {
		return fmt.Errorf("cannot encode the fixed Kubernetes Secret: %s/%s", spec.namespace, spec.kubernetes)
	}
	output, err := runCommand("failed to reconcile Kubernetes Secret: "+spec.namespace+"/"+spec.kubernetes, payload, "kubectl", "--context="+a.context, "apply", "--server-side", "--force-conflicts", "--field-manager="+fieldManager, "-f", "-", "-o", "name")
	if err != nil {
		return err
	}
	if strings.TrimSpace(string(output)) != "secret/"+spec.kubernetes {
		return fmt.Errorf("Kubernetes returned an unexpected reconciliation identity: %s/%s", spec.namespace, spec.kubernetes)
	}
	return nil
}

func (a *adopter) removeLastApplied(spec sourceSpec, existing *kubernetesSecret) error {
	if _, exists := existing.Metadata.Annotations["kubectl.kubernetes.io/last-applied-configuration"]; !exists {
		return nil
	}
	patch := []map[string]string{
		{"op": "test", "path": "/metadata/uid", "value": existing.Metadata.UID},
		{"op": "test", "path": "/metadata/resourceVersion", "value": existing.Metadata.ResourceVersion},
		{"op": "remove", "path": "/metadata/annotations/kubectl.kubernetes.io~1last-applied-configuration"},
	}
	payload, err := json.Marshal(patch)
	if err != nil {
		return fmt.Errorf("cannot encode last-applied cleanup for %s/%s", spec.namespace, spec.kubernetes)
	}
	output, err := runCommand("failed to remove last-applied annotation from "+spec.namespace+"/"+spec.kubernetes, payload, "kubectl", "--context="+a.context, "-n", spec.namespace, "patch", "secret", spec.kubernetes, "--type=json", "--patch-file=/dev/stdin", "--field-manager="+fieldManager, "-o", "name")
	if err != nil {
		return err
	}
	if strings.TrimSpace(string(output)) != "secret/"+spec.kubernetes {
		return fmt.Errorf("Kubernetes returned an unexpected cleanup identity: %s/%s", spec.namespace, spec.kubernetes)
	}
	return nil
}

func buildEnvelope(spec sourceSpec, data map[string][]byte) ([]byte, error) {
	encoded := make(map[string]string, len(spec.keys))
	for _, key := range spec.keys {
		encoded[key] = base64.StdEncoding.EncodeToString(data[key])
	}
	payload, err := json.Marshal(envelope{Schema: payloadSchema, Data: encoded})
	if err != nil || len(payload) == 0 || len(payload) > 65536 {
		return nil, fmt.Errorf("validated envelope size is invalid: %s", spec.logical)
	}
	return payload, nil
}

func compareEnvelope(spec sourceSpec, expected map[string][]byte, payload []byte) error {
	if err := rejectDuplicateJSONKeys(payload); err != nil {
		return fmt.Errorf("existing Secret Manager envelope is invalid: %s", spec.secretID)
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(payload, &raw); err != nil || !exactRawKeys(raw, []string{"schema", "data"}) {
		return fmt.Errorf("existing Secret Manager envelope has an unexpected shape: %s", spec.secretID)
	}
	var schema string
	var values map[string]string
	if json.Unmarshal(raw["schema"], &schema) != nil || schema != payloadSchema || json.Unmarshal(raw["data"], &values) != nil || !exactKeys(values, spec.keys) {
		return fmt.Errorf("existing Secret Manager envelope does not match the fixed contract: %s", spec.secretID)
	}
	for _, key := range spec.keys {
		decoded, err := decodeCanonicalBase64(values[key])
		if err != nil || !bytes.Equal(decoded, expected[key]) {
			return fmt.Errorf("existing Secret Manager envelope differs from the Kubernetes source: %s", spec.secretID)
		}
	}
	return nil
}

func cloneData(input map[string][]byte) map[string][]byte {
	result := make(map[string][]byte, len(input))
	for key, value := range input {
		result[key] = append([]byte(nil), value...)
	}
	return result
}

func equalData(left, right map[string][]byte) bool {
	if len(left) != len(right) {
		return false
	}
	for key, value := range left {
		if !bytes.Equal(value, right[key]) {
			return false
		}
	}
	return true
}

func managedLabelsValid(labels map[string]string) bool {
	return labels["app.kubernetes.io/managed-by"] == "yourown-chat-secret-bootstrap" &&
		labels["app.kubernetes.io/part-of"] == "kagent-substrate-testbed" &&
		labels["platform.yourown.chat/secret-contract"] == "v1"
}

func exactKeys[T any](values map[string]T, expected []string) bool {
	if len(values) != len(expected) {
		return false
	}
	for _, key := range expected {
		if _, exists := values[key]; !exists {
			return false
		}
	}
	return true
}

func exactRawKeys(values map[string]json.RawMessage, expected []string) bool {
	return exactKeys(values, expected)
}

func rejectDuplicateJSONKeys(data []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := scanJSONValue(decoder); err != nil {
		return err
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("multiple JSON values")
		}
		return err
	}
	return nil
}

func scanJSONValue(decoder *json.Decoder) error {
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	delim, isDelim := token.(json.Delim)
	if !isDelim {
		return nil
	}
	switch delim {
	case '{':
		seen := map[string]struct{}{}
		for decoder.More() {
			keyToken, err := decoder.Token()
			if err != nil {
				return err
			}
			key, ok := keyToken.(string)
			if !ok {
				return errors.New("JSON object key is not a string")
			}
			if _, duplicate := seen[key]; duplicate {
				return errors.New("duplicate JSON key")
			}
			seen[key] = struct{}{}
			if err := scanJSONValue(decoder); err != nil {
				return err
			}
		}
		end, err := decoder.Token()
		if err != nil || end != json.Delim('}') {
			return errors.New("unterminated JSON object")
		}
	case '[':
		for decoder.More() {
			if err := scanJSONValue(decoder); err != nil {
				return err
			}
		}
		end, err := decoder.Token()
		if err != nil || end != json.Delim(']') {
			return errors.New("unterminated JSON array")
		}
	default:
		return errors.New("unexpected JSON delimiter")
	}
	return nil
}

func decodeCanonicalBase64(value string) ([]byte, error) {
	decoded, err := base64.StdEncoding.Strict().DecodeString(value)
	if err != nil || len(decoded) == 0 || base64.StdEncoding.EncodeToString(decoded) != value {
		return nil, errors.New("invalid canonical base64")
	}
	return decoded, nil
}

func validatePostgresURI(raw []byte) error {
	if len(raw) == 0 || !utf8.Valid(raw) || bytes.IndexByte(raw, 0) >= 0 || bytes.ContainsAny(raw, "\r\n") {
		return errors.New("PostgreSQL connection string must be one non-empty line without NUL")
	}
	parsed, err := url.Parse(string(raw))
	if err != nil || (parsed.Scheme != "postgres" && parsed.Scheme != "postgresql") || parsed.Hostname() == "" || parsed.User == nil || parsed.User.Username() == "" || parsed.Path == "" || parsed.Path == "/" {
		return errors.New("PostgreSQL connection string is missing scheme, credentials, host or database")
	}
	if _, present := parsed.User.Password(); !present {
		return errors.New("PostgreSQL connection string is missing scheme, credentials, host or database")
	}
	if port := parsed.Port(); port != "" && port != "5432" {
		return errors.New("PostgreSQL connection string must use port 5432 when a port is explicit")
	}
	return nil
}

type parsedCredential struct {
	leaf  *x509.Certificate
	chain []*x509.Certificate
}

func parsePrivateKey(der []byte, blockType string) (crypto.Signer, error) {
	var candidate any
	var err error
	switch blockType {
	case "PRIVATE KEY":
		candidate, err = x509.ParsePKCS8PrivateKey(der)
	case "RSA PRIVATE KEY":
		candidate, err = x509.ParsePKCS1PrivateKey(der)
	case "EC PRIVATE KEY":
		candidate, err = x509.ParseECPrivateKey(der)
	default:
		return nil, errors.New("unsupported private key type")
	}
	if err != nil {
		return nil, errors.New("invalid private key")
	}
	signer, ok := candidate.(crypto.Signer)
	if !ok {
		return nil, errors.New("private key cannot sign")
	}
	return signer, nil
}

func parseCredentialBundle(raw []byte) (*parsedCredential, error) {
	rest := raw
	blocks := make([]*pem.Block, 0, 4)
	for {
		block, remaining := pem.Decode(rest)
		if block == nil {
			if len(bytes.TrimSpace(rest)) != 0 {
				return nil, errors.New("credential bundle contains data outside PEM blocks")
			}
			break
		}
		blocks = append(blocks, block)
		rest = remaining
	}
	if len(blocks) < 2 {
		return nil, errors.New("credential bundle is incomplete")
	}
	key, err := parsePrivateKey(blocks[0].Bytes, blocks[0].Type)
	if err != nil {
		return nil, err
	}
	certificates := make([]*x509.Certificate, 0, len(blocks)-1)
	for _, block := range blocks[1:] {
		if block.Type != "CERTIFICATE" {
			return nil, errors.New("credential bundle must be one private key followed by certificates")
		}
		certificate, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return nil, errors.New("credential bundle contains an invalid certificate")
		}
		certificates = append(certificates, certificate)
	}
	if err := publicKeysEqual(key.Public(), certificates[0].PublicKey); err != nil {
		return nil, errors.New("credential private key does not match the leaf certificate")
	}
	return &parsedCredential{leaf: certificates[0], chain: certificates[1:]}, nil
}

func parseCABundle(raw []byte) ([]*x509.Certificate, error) {
	rest := raw
	certificates := make([]*x509.Certificate, 0, 2)
	for {
		block, remaining := pem.Decode(rest)
		if block == nil {
			if len(bytes.TrimSpace(rest)) != 0 {
				return nil, errors.New("trust bundle contains data outside PEM blocks")
			}
			break
		}
		if block.Type != "CERTIFICATE" {
			return nil, errors.New("trust bundle contains non-certificate PEM material")
		}
		certificate, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return nil, errors.New("trust bundle contains an invalid certificate")
		}
		certificates = append(certificates, certificate)
		rest = remaining
	}
	if len(certificates) == 0 {
		return nil, errors.New("trust bundle contains no certificate")
	}
	return certificates, nil
}

func publicKeysEqual(left, right any) error {
	leftDER, err := x509.MarshalPKIXPublicKey(left)
	if err != nil {
		return err
	}
	rightDER, err := x509.MarshalPKIXPublicKey(right)
	if err != nil {
		return err
	}
	if !bytes.Equal(leftDER, rightDER) {
		return errors.New("public keys differ")
	}
	return nil
}

func verifyCredential(credential *parsedCredential, trustPEM []byte, usage x509.ExtKeyUsage) error {
	trust, err := parseCABundle(trustPEM)
	if err != nil {
		return err
	}
	roots := x509.NewCertPool()
	for _, certificate := range trust {
		roots.AddCert(certificate)
	}
	intermediates := x509.NewCertPool()
	for _, certificate := range credential.chain {
		intermediates.AddCert(certificate)
	}
	_, err = credential.leaf.Verify(x509.VerifyOptions{
		Roots:         roots,
		Intermediates: intermediates,
		KeyUsages:     []x509.ExtKeyUsage{usage},
		CurrentTime:   time.Now(),
	})
	if err != nil {
		return errors.New("certificate chain is not trusted for its required TLS purpose")
	}
	return nil
}

func requireDNSName(certificate *x509.Certificate, expected string) error {
	for _, name := range certificate.DNSNames {
		if name == expected {
			return nil
		}
	}
	return errors.New("certificate is missing the required DNS SAN")
}

func requireURI(certificate *x509.Certificate, expected string) error {
	for _, value := range certificate.URIs {
		if value.String() == expected {
			return nil
		}
	}
	return errors.New("certificate is missing the required URI SAN")
}

func objectWithExactKeys(raw []byte, expected []string) (map[string]json.RawMessage, error) {
	if err := rejectDuplicateJSONKeys(raw); err != nil {
		return nil, err
	}
	var object map[string]json.RawMessage
	if err := json.Unmarshal(raw, &object); err != nil || !exactRawKeys(object, expected) {
		return nil, errors.New("JSON object has an unexpected shape")
	}
	return object, nil
}

func decodeString(raw json.RawMessage) (string, error) {
	var value string
	if err := json.Unmarshal(raw, &value); err != nil {
		return "", err
	}
	return value, nil
}

func validateJWTPool(raw []byte) error {
	object, err := objectWithExactKeys(raw, []string{"Authorities"})
	if err != nil {
		return errors.New("JWT pool has an unexpected shape")
	}
	var authorities []json.RawMessage
	if json.Unmarshal(object["Authorities"], &authorities) != nil || len(authorities) == 0 {
		return errors.New("JWT pool must contain a non-empty Authorities array")
	}
	ids := map[string]struct{}{}
	for _, authorityRaw := range authorities {
		authority, err := objectWithExactKeys(authorityRaw, []string{"ID", "Algorithm", "SigningKeyPKCS8", "SigningKeyPEM"})
		if err != nil {
			return errors.New("JWT authority has an unexpected shape")
		}
		id, errID := decodeString(authority["ID"])
		algorithm, errAlgorithm := decodeString(authority["Algorithm"])
		encodedKey, errKey := decodeString(authority["SigningKeyPKCS8"])
		pemKey, errPEM := decodeString(authority["SigningKeyPEM"])
		if errID != nil || errAlgorithm != nil || errKey != nil || errPEM != nil || id == "" || algorithm != "ES256" || pemKey != "" {
			return errors.New("JWT authority ID, algorithm or key encoding is invalid")
		}
		if _, duplicate := ids[id]; duplicate {
			return errors.New("JWT authority IDs must be unique")
		}
		ids[id] = struct{}{}
		keyDER, err := decodeCanonicalBase64(encodedKey)
		if err != nil {
			return errors.New("JWT authority PKCS8 key is invalid")
		}
		parsed, err := x509.ParsePKCS8PrivateKey(keyDER)
		key, ok := parsed.(*ecdsa.PrivateKey)
		if err != nil || !ok || key.Curve.Params().Name != "P-256" {
			return errors.New("JWT authority is not an ECDSA P-256 private key")
		}
	}
	return nil
}

func validateCAPoolAndDerive(raw []byte) ([]byte, error) {
	object, err := objectWithExactKeys(raw, []string{"CAs"})
	if err != nil {
		return nil, errors.New("CA pool has an unexpected shape")
	}
	var entries []json.RawMessage
	if json.Unmarshal(object["CAs"], &entries) != nil || len(entries) == 0 {
		return nil, errors.New("CA pool must contain a non-empty CAs array")
	}
	ids := map[string]struct{}{}
	var firstCertificate *x509.Certificate
	for _, entryRaw := range entries {
		entry, err := objectWithExactKeys(entryRaw, []string{"ID", "SigningKeyPKCS8", "SigningKeyPEM", "RootCertificateDER", "RootCertificatePEM", "IntermediateCertificatesDER"})
		if err != nil {
			return nil, errors.New("CA entry has an unexpected shape")
		}
		id, errID := decodeString(entry["ID"])
		encodedKey, errKey := decodeString(entry["SigningKeyPKCS8"])
		pemKey, errPEMKey := decodeString(entry["SigningKeyPEM"])
		encodedCertificate, errCertificate := decodeString(entry["RootCertificateDER"])
		pemCertificate, errPEMCertificate := decodeString(entry["RootCertificatePEM"])
		if errID != nil || errKey != nil || errPEMKey != nil || errCertificate != nil || errPEMCertificate != nil || id == "" || pemKey != "" || pemCertificate != "" {
			return nil, errors.New("CA entry ID, key or certificate encoding is invalid")
		}
		if _, duplicate := ids[id]; duplicate {
			return nil, errors.New("CA entry IDs must be unique")
		}
		ids[id] = struct{}{}
		if string(bytes.TrimSpace(entry["IntermediateCertificatesDER"])) != "null" {
			var intermediates []string
			if json.Unmarshal(entry["IntermediateCertificatesDER"], &intermediates) != nil || len(intermediates) != 0 {
				return nil, errors.New("CA intermediate certificates are not supported by the root-only contract")
			}
		}
		keyDER, err := decodeCanonicalBase64(encodedKey)
		if err != nil {
			return nil, errors.New("CA private key is invalid")
		}
		parsedKey, err := x509.ParsePKCS8PrivateKey(keyDER)
		signer, ok := parsedKey.(crypto.Signer)
		if err != nil || !ok {
			return nil, errors.New("CA private key is invalid")
		}
		certificateDER, err := decodeCanonicalBase64(encodedCertificate)
		if err != nil {
			return nil, errors.New("CA root certificate is invalid")
		}
		certificate, err := x509.ParseCertificate(certificateDER)
		if err != nil || !certificate.BasicConstraintsValid || !certificate.IsCA || certificate.KeyUsage&x509.KeyUsageCertSign == 0 {
			return nil, errors.New("CA root certificate does not permit certificate signing")
		}
		now := time.Now()
		if now.Before(certificate.NotBefore) || now.After(certificate.NotAfter) {
			return nil, errors.New("CA root certificate is not currently valid")
		}
		if certificate.CheckSignatureFrom(certificate) != nil {
			return nil, errors.New("CA root certificate is not self-signed")
		}
		if publicKeysEqual(signer.Public(), certificate.PublicKey) != nil {
			return nil, errors.New("CA private key does not match its root certificate")
		}
		if firstCertificate == nil {
			firstCertificate = certificate
		}
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: firstCertificate.Raw}), nil
}

func validateMaterializedContract(data map[string]map[string][]byte) ([]byte, error) {
	if err := validatePostgresURI(data["postgres"]["connection-string"]); err != nil {
		return nil, err
	}
	if err := validateJWTPool(data["actor_id_jwt_pool"]["pool"]); err != nil {
		return nil, err
	}
	derived, err := validateCAPoolAndDerive(data["actor_id_ca_pool"]["pool"])
	if err != nil {
		return nil, err
	}

	apiClientCA := data["api_tls"]["client-ca.pem"]
	controllerServerCA := data["controller_tls"]["server-ca.pem"]
	egressServerCA := data["egress_gateway_tls"]["server-ca.pem"]
	egressClientServerCA := data["egress_authorizer_tls"]["server-ca.pem"]
	kagentServerCA := data["kagent_client_tls"]["server-ca.pem"]
	kagentDevServerCA := data["kagent_dev_client_tls"]["server-ca.pem"]
	for _, trust := range [][]byte{apiClientCA, controllerServerCA, egressServerCA, egressClientServerCA, kagentServerCA, kagentDevServerCA} {
		if _, err := parseCABundle(trust); err != nil {
			return nil, err
		}
	}

	apiServer, err := parseCredentialBundle(data["api_tls"]["server-credential-bundle.pem"])
	if err != nil {
		return nil, err
	}
	if err := requireDNSName(apiServer.leaf, "api.ate-system.svc"); err != nil {
		return nil, err
	}
	for _, trust := range [][]byte{controllerServerCA, egressClientServerCA, kagentServerCA, kagentDevServerCA} {
		if err := verifyCredential(apiServer, trust, x509.ExtKeyUsageServerAuth); err != nil {
			return nil, err
		}
	}

	egressServer, err := parseCredentialBundle(data["egress_gateway_tls"]["server-credential-bundle.pem"])
	if err != nil {
		return nil, err
	}
	if err := requireDNSName(egressServer.leaf, "atenet-egress.ate-system.svc"); err != nil {
		return nil, err
	}
	if err := verifyCredential(egressServer, egressServerCA, x509.ExtKeyUsageServerAuth); err != nil {
		return nil, err
	}

	clients := []struct {
		logical string
		key     string
		uri     string
	}{
		{logical: "controller_tls", key: "client-credential-bundle.pem", uri: "spiffe://cluster.local/ns/ate-system/sa/ate-controller"},
		{logical: "egress_authorizer_tls", key: "client-credential-bundle.pem", uri: "spiffe://cluster.local/ns/ate-system/sa/atenet-egress"},
		{logical: "kagent_client_tls", key: "client-credential-bundle.pem", uri: "spiffe://cluster.local/ns/kagent-system/sa/kagent-controller"},
		{logical: "kagent_dev_client_tls", key: "client-credential-bundle.pem", uri: "spiffe://cluster.local/ns/kagent-dev/sa/kagent-controller"},
	}
	for _, client := range clients {
		credential, err := parseCredentialBundle(data[client.logical][client.key])
		if err != nil {
			return nil, err
		}
		if err := requireURI(credential.leaf, client.uri); err != nil {
			return nil, err
		}
		if err := verifyCredential(credential, apiClientCA, x509.ExtKeyUsageClientAuth); err != nil {
			return nil, err
		}
	}
	return derived, nil
}
