// Package config loads and validates a flavor's config.toml.
package config

import (
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"

	"github.com/BurntSushi/toml"
)

type Mount struct {
	Path string `toml:"path"`
	RW   bool   `toml:"rw"`
}

type Config struct {
	Image      string            `toml:"image"`
	ForwardSSH bool              `toml:"forward_ssh"`
	DNS        []string          `toml:"dns"`
	Env        map[string]string `toml:"env"`
	Mounts     []Mount           `toml:"mounts"`
}

var KnownKeys = []string{"image", "forward_ssh", "dns", "env", "mounts"}

// Env keys must be valid shell-style names because the env file is line-based.
var envKeyPattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// rawConfig decodes env loosely so non-string values produce a precise error
// instead of a generic type mismatch.
type rawConfig struct {
	Image      string         `toml:"image"`
	ForwardSSH bool           `toml:"forward_ssh"`
	DNS        []string       `toml:"dns"`
	Env        map[string]any `toml:"env"`
	Mounts     []Mount        `toml:"mounts"`
}

func Load(path string) (Config, []string, error) {
	var raw rawConfig
	metadata, err := toml.DecodeFile(path, &raw)
	if err != nil {
		if parseError, ok := err.(toml.ParseError); ok {
			return Config{}, nil, fmt.Errorf("%s: line %d: %s", path, parseError.Position.Line, parseError.Message)
		}
		return Config{}, nil, fmt.Errorf("%s: %w", path, err)
	}

	var warnings []string
	for _, key := range metadata.Undecoded() {
		warnings = append(warnings, fmt.Sprintf(
			">> config.toml: unrecognized key '%s' (known keys: %s); ignored",
			key.String(), strings.Join(KnownKeys, ", ")))
	}

	loaded := Config{
		Image:      raw.Image,
		ForwardSSH: raw.ForwardSSH,
		DNS:        raw.DNS,
		Mounts:     raw.Mounts,
	}
	if raw.Env != nil {
		loaded.Env = make(map[string]string, len(raw.Env))
	}
	for key, value := range raw.Env {
		if !envKeyPattern.MatchString(key) {
			return Config{}, nil, fmt.Errorf("%s: [env] key %q is not a valid environment variable name", path, key)
		}
		text, ok := value.(string)
		if !ok {
			return Config{}, nil, fmt.Errorf("%s: [env] %s must be a string, got %T", path, key, value)
		}
		if strings.ContainsAny(text, "\r\n") {
			return Config{}, nil, fmt.Errorf("%s: [env] %s must not contain a newline", path, key)
		}
		loaded.Env[key] = text
	}
	return loaded, warnings, nil
}

func WriteEnvFile(path string, env map[string]string) error {
	keys := make([]string, 0, len(env))
	for key := range env {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	var builder strings.Builder
	for _, key := range keys {
		builder.WriteString(key + "=" + env[key] + "\n")
	}
	if err := os.WriteFile(path, []byte(builder.String()), 0o600); err != nil {
		return err
	}
	// WriteFile's mode only applies on creation.
	return os.Chmod(path, 0o600)
}
