package paths

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const namespace = "claude-container"

type Paths struct {
	Flavor              string
	ConfigDir           string
	StateDir            string
	StateClaudeDir      string
	HostDotClaude       string
	HostDotClaudeLegacy string
	ProjectKey          string
	HostProjectDir      string
	HostConfig          string
	HostSettings        string
}

// Resolve mirrors the host-side path block of the bash launcher.
func Resolve(flavor, workingDirectory, home string, getenv func(string) string) Paths {
	configHome := getenv("XDG_CONFIG_HOME")
	if configHome == "" {
		configHome = filepath.Join(home, ".config")
	}
	stateHome := getenv("XDG_STATE_HOME")
	if stateHome == "" {
		stateHome = filepath.Join(home, ".local", "state")
	}
	configDir := filepath.Join(configHome, namespace, flavor)
	stateDir := filepath.Join(stateHome, namespace, flavor)
	stateClaudeDir := filepath.Join(stateDir, "claude")
	projectKey := ProjectKey(workingDirectory)

	hostConfig := getenv("CLAUDE_CONFIG")
	if hostConfig == "" {
		hostConfig = filepath.Join(configDir, "config.toml")
	}
	hostSettings := getenv("CLAUDE_SETTINGS")
	if hostSettings == "" {
		hostSettings = filepath.Join(configDir, "settings.override.json")
	}

	return Paths{
		Flavor:              flavor,
		ConfigDir:           configDir,
		StateDir:            stateDir,
		StateClaudeDir:      stateClaudeDir,
		HostDotClaude:       filepath.Join(stateClaudeDir, "claude.json"),
		HostDotClaudeLegacy: filepath.Join(stateDir, "claude.json"),
		ProjectKey:          projectKey,
		HostProjectDir:      filepath.Join(stateDir, "projects", projectKey),
		HostConfig:          hostConfig,
		HostSettings:        hostSettings,
	}
}

// ProjectKey must match the bash launcher byte for byte, or existing
// per-project memory directories are orphaned.
func ProjectKey(workingDirectory string) string {
	slug := strings.ReplaceAll(workingDirectory, "/", "-")
	return slug + "-" + strconv.FormatUint(uint64(POSIXCksum([]byte(workingDirectory))), 10)
}

// POSIXCksum is the CRC of cksum(1): polynomial 0x04C11DB7, MSB-first,
// with the length appended and the result complemented.
func POSIXCksum(data []byte) uint32 {
	var crc uint32
	update := func(value byte) {
		crc ^= uint32(value) << 24
		for bit := 0; bit < 8; bit++ {
			if crc&0x80000000 != 0 {
				crc = crc<<1 ^ 0x04C11DB7
			} else {
				crc <<= 1
			}
		}
	}
	for _, value := range data {
		update(value)
	}
	for length := uint64(len(data)); length != 0; length >>= 8 {
		update(byte(length))
	}
	return ^crc
}

// WorkingDirectory prefers $PWD (which keeps symlinks, matching bash) when
// it still names the current directory.
func WorkingDirectory(getenv func(string) string) (string, error) {
	if pwd := getenv("PWD"); pwd != "" {
		pwdInfo, pwdErr := os.Stat(pwd)
		currentInfo, currentErr := os.Stat(".")
		if pwdErr == nil && currentErr == nil && os.SameFile(pwdInfo, currentInfo) {
			return pwd, nil
		}
	}
	return os.Getwd()
}
