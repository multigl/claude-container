package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/multigl/claude-container/internal/paths"
)

// LegacyFiles holds the paths of pre-config.toml files that exist; absent ones are empty.
type LegacyFiles struct {
	LauncherConf string
	Env          string
	Mounts       string
}

func (l LegacyFiles) Any() bool {
	return l.LauncherConf != "" || l.Env != "" || l.Mounts != ""
}

func FindLegacy(p paths.Paths, getenv func(string) string) LegacyFiles {
	return LegacyFiles{
		LauncherConf: existingFile(filepath.Join(p.ConfigDir, "launcher.conf")),
		Env:          existingFile(overridePath(getenv, "CLAUDE_ENV_FILE", filepath.Join(p.ConfigDir, "env"))),
		Mounts:       existingFile(overridePath(getenv, "CLAUDE_MOUNTS_FILE", filepath.Join(p.ConfigDir, "mounts"))),
	}
}

func overridePath(getenv func(string) string, variable, defaultPath string) string {
	if override := getenv(variable); override != "" {
		return override
	}
	return defaultPath
}

func existingFile(path string) string {
	if info, err := os.Stat(path); err == nil && info.Mode().IsRegular() {
		return path
	}
	return ""
}

// Migrate converts the legacy files into config.toml text. The report lists
// every line that could not be carried over.
func Migrate(l LegacyFiles) (tomlText string, report []string, err error) {
	var sources []string
	var topLevel, envSection, mountsSection strings.Builder

	if l.LauncherConf != "" {
		sources = append(sources, l.LauncherConf)
		lines, readErr := readLines(l.LauncherConf)
		if readErr != nil {
			return "", nil, readErr
		}
		report = append(report, migrateLauncherConf(l.LauncherConf, lines, &topLevel)...)
	}
	if l.Env != "" {
		sources = append(sources, l.Env)
		lines, readErr := readLines(l.Env)
		if readErr != nil {
			return "", nil, readErr
		}
		report = append(report, migrateEnv(l.Env, lines, &envSection)...)
	}
	if l.Mounts != "" {
		sources = append(sources, l.Mounts)
		lines, readErr := readLines(l.Mounts)
		if readErr != nil {
			return "", nil, readErr
		}
		migrateMounts(lines, &mountsSection)
	}

	var output strings.Builder
	output.WriteString("# Migrated from legacy files: " + strings.Join(sources, ", ") + "\n\n")
	output.WriteString(topLevel.String())
	if envSection.Len() > 0 {
		output.WriteString("\n[env]\n" + envSection.String())
	}
	output.WriteString(mountsSection.String())
	return output.String(), report, nil
}

func readLines(path string) ([]string, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	lines := strings.Split(string(content), "\n")
	for index := range lines {
		lines[index] = strings.TrimSuffix(lines[index], "\r")
	}
	return lines, nil
}

func migrateLauncherConf(path string, lines []string, out *strings.Builder) []string {
	var report []string
	values := map[string]string{}
	for _, line := range lines {
		line, _, _ = strings.Cut(line, "#")
		key, value, found := strings.Cut(line, "=")
		if !found {
			continue
		}
		key, value = strings.TrimSpace(key), strings.TrimSpace(value)
		if _, known := map[string]bool{"forward_ssh": true, "dns": true, "image": true}[key]; !known {
			report = append(report, fmt.Sprintf("%s: unknown key %q dropped", path, key))
			continue
		}
		// First occurrence wins, matching the bash reader.
		if _, seen := values[key]; !seen {
			values[key] = value
		}
	}
	if value, ok := values["image"]; ok && value != "" {
		out.WriteString("image = " + quoteTOMLString(value) + "\n")
	}
	if value, ok := values["forward_ssh"]; ok {
		switch strings.ToLower(value) {
		case "1", "true", "yes":
			out.WriteString("forward_ssh = true\n")
		default:
			out.WriteString("forward_ssh = false\n")
		}
	}
	if servers := strings.FieldsFunc(values["dns"], func(r rune) bool { return r == ',' || r == ' ' || r == '\t' }); len(servers) > 0 {
		quoted := make([]string, len(servers))
		for index, server := range servers {
			quoted[index] = quoteTOMLString(server)
		}
		out.WriteString("dns = [" + strings.Join(quoted, ", ") + "]\n")
	}
	return report
}

func migrateEnv(path string, lines []string, out *strings.Builder) []string {
	var report []string
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		if strings.HasPrefix(trimmed, "#") {
			out.WriteString(trimmed + "\n")
			continue
		}
		key, value, found := strings.Cut(line, "=")
		key = strings.TrimSpace(key)
		switch {
		case !found:
			report = append(report, fmt.Sprintf("%s: %q is a host passthrough with no value; dropped", path, key))
		case !envKeyPattern.MatchString(key):
			report = append(report, fmt.Sprintf("%s: invalid variable name %q dropped", path, key))
		default:
			out.WriteString(key + " = " + quoteTOMLString(value) + "\n")
		}
	}
	return report
}

func migrateMounts(lines []string, out *strings.Builder) {
	for _, line := range lines {
		line, _, _ = strings.Cut(line, "#")
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		readWrite := strings.HasSuffix(line, ":rw")
		if readWrite {
			line = strings.TrimSpace(strings.TrimSuffix(line, ":rw"))
		}
		out.WriteString("\n[[mounts]]\npath = " + quoteTOMLString(line) + "\n")
		if readWrite {
			out.WriteString("rw = true\n")
		}
	}
}

// quoteTOMLString writes a TOML basic string; strconv.Quote is unsuitable
// because it can emit \x escapes, which TOML rejects.
func quoteTOMLString(text string) string {
	var builder strings.Builder
	builder.WriteByte('"')
	for _, character := range text {
		switch {
		case character == '\\':
			builder.WriteString(`\\`)
		case character == '"':
			builder.WriteString(`\"`)
		case character == '\t':
			builder.WriteString(`\t`)
		case character == '\n':
			builder.WriteString(`\n`)
		case character == '\r':
			builder.WriteString(`\r`)
		case character < 0x20 || character == 0x7f:
			fmt.Fprintf(&builder, `\u%04X`, character)
		default:
			builder.WriteRune(character)
		}
	}
	builder.WriteByte('"')
	return builder.String()
}
