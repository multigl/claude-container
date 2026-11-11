// Package launch builds the container run arguments for the launcher.
package launch

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/multigl/claude-container/internal/config"
	"github.com/multigl/claude-container/internal/runtime"
)

var ipAddressShape = regexp.MustCompile(`^[0-9A-Fa-f.:]+$`)

func isTruthy(value string) bool {
	switch strings.ToLower(value) {
	case "1", "true", "yes":
		return true
	}
	return false
}

// DNSServers returns CLAUDE_DNS (split on commas and whitespace) when set,
// otherwise the configured servers.
func DNSServers(getenv func(string) string, cfg config.Config) []string {
	if value := getenv("CLAUDE_DNS"); value != "" {
		return strings.FieldsFunc(value, func(character rune) bool {
			return character == ',' || character == ' ' || character == '\t' || character == '\n'
		})
	}
	return cfg.DNS
}

// DNSFlags emits one --dns flag per server. Tokens must be IP-shaped so a
// stray value can never become a run flag.
func DNSFlags(servers []string) (flags []string, warnings []string) {
	for _, server := range servers {
		if ipAddressShape.MatchString(server) {
			flags = append(flags, "--dns", server)
		} else {
			warnings = append(warnings, fmt.Sprintf(">> dns: '%s' is not an IP address; ignored", server))
		}
	}
	return flags, warnings
}

// MountFlags mounts each approved directory at /mnt/approved/<basename>,
// read-only unless RW. Missing dirs and basename collisions are skipped with
// a warning so a stale entry never blocks launch.
func MountFlags(mounts []config.Mount, home string) (flags []string, warnings []string) {
	seenNames := map[string]bool{}
	for _, mount := range mounts {
		path := strings.TrimSpace(mount.Path)
		if strings.HasPrefix(path, "~") {
			path = home + path[1:]
		}
		if info, err := os.Stat(path); err != nil || !info.IsDir() {
			warnings = append(warnings, fmt.Sprintf(">> skip mount: not a directory: %s", path))
			continue
		}
		name := filepath.Base(path)
		if seenNames[name] {
			warnings = append(warnings, fmt.Sprintf(">> skip mount: duplicate basename '%s' (%s)", name, path))
			continue
		}
		seenNames[name] = true
		mode := "ro"
		if mount.RW {
			mode = "rw"
		}
		flags = append(flags, "-v", fmt.Sprintf("%s:/mnt/approved/%s:%s", path, name, mode))
	}
	return flags, warnings
}

// SSHEnabled lets CLAUDE_FORWARD_SSH override the configured value.
func SSHEnabled(getenv func(string) string, cfg config.Config) bool {
	if value := getenv("CLAUDE_FORWARD_SSH"); value != "" {
		return isTruthy(value)
	}
	return cfg.ForwardSSH
}

// SSHSupported: apple anywhere, or docker/podman on Linux. Not macOS Docker
// Desktop, whose host-services bridge can't forward the 1Password agent.
func SSHSupported(runtimeName string, host runtime.Host) bool {
	if runtimeName == "apple" {
		return true
	}
	return host.OS == "Linux" && (runtimeName == "docker" || runtimeName == "podman")
}
