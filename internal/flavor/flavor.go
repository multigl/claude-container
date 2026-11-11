// Package flavor holds the per-flavor drivers: credentials, auth, seed config, doctor.
package flavor

import (
	"fmt"
	"sort"
	"strings"

	"github.com/multigl/claude-container/internal/config"
	"github.com/multigl/claude-container/internal/paths"
)

type Flavor interface {
	Name() string
	CredDirs() []string
	CredPaths() []string
	RunFlags() []string
	// AuthCommand is the argv to run in the container, with the messages
	// printed before and after it.
	AuthCommand() (command []string, before, after string)
	// SeedConfig is the complete config.toml written on first launch.
	SeedConfig() string
	PrintPaths() []string
	Doctor(cfg config.Config) []string
	// LegacyVolume is the old named cred volume, or empty if there never was one.
	LegacyVolume() string
}

func Known() []string {
	names := []string{"gateway", "personal", "vertex"}
	sort.Strings(names)
	return names
}

func New(name string, p paths.Paths) (Flavor, error) {
	switch name {
	case "vertex":
		return newVertex(p), nil
	case "gateway":
		return newGateway(p), nil
	case "personal":
		return newPersonal(p), nil
	}
	return nil, fmt.Errorf("unknown flavor %q (known: %s)", name, strings.Join(Known(), " "))
}

const seedHeader = `# claude-container config. Every option is shown here; uncomment to use.
# image = "claude-%s:latest"   # run a locally built image instead of the published one
# forward_ssh = true           # forward the host SSH agent (and SSH commit signing)
# dns = ["192.168.64.1"]       # --dns servers for the container

[env]
`

const seedMountsExample = `
# Extra host dirs, mounted at /mnt/approved/<basename>; read-only unless rw = true.
# [[mounts]]
# path = "/path/to/dir"
# rw = false
`

func seedConfig(flavorName string, envBlocks ...string) string {
	return fmt.Sprintf(seedHeader, flavorName) + strings.Join(envBlocks, "\n") + seedMountsExample
}

func atlassianBlock() string {
	return `# Atlassian MCP credentials.
# API tokens: https://id.atlassian.com/manage-profile/security/api-tokens
JIRA_URL = ""
JIRA_USERNAME = ""
JIRA_API_TOKEN = ""
CONFLUENCE_URL = ""
CONFLUENCE_USERNAME = ""
CONFLUENCE_API_TOKEN = ""
`
}

func context7Block() string {
	return `# Context7 MCP. API key: https://context7.com (account -> API key)
CONTEXT7_API_KEY = ""
`
}

// doctorPlaceholderProjects are values that mean "not configured".
var doctorPlaceholderProjects = map[string]bool{
	"":                 true,
	"your-gcp-project": true,
	"your-project":     true,
	"CHANGEME":         true,
}
