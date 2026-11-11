package config

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/multigl/claude-container/internal/paths"
)

func writeFile(t *testing.T, directory, name, content string) string {
	t.Helper()
	path := filepath.Join(directory, name)
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestFindLegacy(t *testing.T) {
	testCases := []struct {
		name  string
		setup func(t *testing.T, directory string) (map[string]string, LegacyFiles)
	}{
		{
			name: "defaults present",
			setup: func(t *testing.T, directory string) (map[string]string, LegacyFiles) {
				want := LegacyFiles{
					LauncherConf: writeFile(t, directory, "launcher.conf", ""),
					Env:          writeFile(t, directory, "env", ""),
					Mounts:       writeFile(t, directory, "mounts", ""),
				}
				return nil, want
			},
		},
		{
			name: "env override exists while default absent",
			setup: func(t *testing.T, directory string) (map[string]string, LegacyFiles) {
				override := writeFile(t, directory, "custom-env", "")
				return map[string]string{"CLAUDE_ENV_FILE": override}, LegacyFiles{Env: override}
			},
		},
		{
			name: "env override missing",
			setup: func(t *testing.T, directory string) (map[string]string, LegacyFiles) {
				writeFile(t, directory, "env", "")
				return map[string]string{"CLAUDE_ENV_FILE": filepath.Join(directory, "nope")}, LegacyFiles{}
			},
		},
		{
			name: "mounts override",
			setup: func(t *testing.T, directory string) (map[string]string, LegacyFiles) {
				override := writeFile(t, directory, "custom-mounts", "")
				return map[string]string{"CLAUDE_MOUNTS_FILE": override}, LegacyFiles{Mounts: override}
			},
		},
	}
	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			directory := t.TempDir()
			environment, want := testCase.setup(t, directory)
			got := FindLegacy(paths.Paths{ConfigDir: directory}, func(key string) string { return environment[key] })
			if got != want {
				t.Errorf("got %+v, want %+v", got, want)
			}
			if got.Any() != (want != LegacyFiles{}) {
				t.Errorf("Any() = %v for %+v", got.Any(), got)
			}
		})
	}
}

func TestMigrate(t *testing.T) {
	testCases := []struct {
		name         string
		launcherConf string
		env          string
		mounts       string
		wantConfig   Config
		wantReport   []string
		wantContains []string
	}{
		{name: "forward_ssh Yes", launcherConf: "forward_ssh = Yes\n", wantConfig: Config{ForwardSSH: true}},
		{name: "forward_ssh 0", launcherConf: "forward_ssh = 0\n", wantConfig: Config{ForwardSSH: false}, wantContains: []string{"forward_ssh = false"}},
		{name: "dns list", launcherConf: "dns = 1.1.1.1, 8.8.8.8\n", wantConfig: Config{DNS: []string{"1.1.1.1", "8.8.8.8"}}},
		{name: "image with inline comment", launcherConf: "image = foo:1 # local\n", wantConfig: Config{Image: "foo:1"}},
		{name: "unknown key reported", launcherConf: "bogus = 1\n", wantReport: []string{"bogus"}},
		{name: "env value keeps hash and equals", env: "TOKEN=abc#def=\n", wantConfig: Config{Env: map[string]string{"TOKEN": "abc#def="}}},
		{
			name:         "env comments preserved in order",
			env:          "# first\nA=1\n  # second\nB=2\n",
			wantConfig:   Config{Env: map[string]string{"A": "1", "B": "2"}},
			wantContains: []string{"# first\nA = \"1\"\n# second\nB = \"2\""},
		},
		{name: "env bare key reported", env: "PASSTHRU\nA=1\n", wantConfig: Config{Env: map[string]string{"A": "1"}}, wantReport: []string{"PASSTHRU"}},
		{
			name:       "mounts ro and rw",
			mounts:     "# note\n~/notes\n~/scratch :rw\n\n~/tight:rw # c\n",
			wantConfig: Config{Mounts: []Mount{{Path: "~/notes"}, {Path: "~/scratch", RW: true}, {Path: "~/tight", RW: true}}},
		},
		{
			name:         "mounts comment dropped",
			mounts:       "# only a comment\n~/a\n",
			wantConfig:   Config{Mounts: []Mount{{Path: "~/a"}}},
			wantContains: nil,
		},
		{
			name:       "awkward env characters round trip",
			env:        "WEIRD=back\\slash \"quoted\"\ttab é\n",
			wantConfig: Config{Env: map[string]string{"WEIRD": "back\\slash \"quoted\"\ttab é"}},
		},
	}
	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			directory := t.TempDir()
			var legacy LegacyFiles
			if testCase.launcherConf != "" {
				legacy.LauncherConf = writeFile(t, directory, "launcher.conf", testCase.launcherConf)
			}
			if testCase.env != "" {
				legacy.Env = writeFile(t, directory, "env", testCase.env)
			}
			if testCase.mounts != "" {
				legacy.Mounts = writeFile(t, directory, "mounts", testCase.mounts)
			}
			text, report, err := Migrate(legacy)
			if err != nil {
				t.Fatal(err)
			}
			if !strings.HasPrefix(text, "# Migrated from legacy files:") {
				t.Errorf("missing header in %q", text)
			}
			if strings.Contains(text, "# note") || strings.Contains(text, "only a comment") {
				t.Errorf("mounts comment leaked into %q", text)
			}
			for _, want := range testCase.wantContains {
				if !strings.Contains(text, want) {
					t.Errorf("output missing %q:\n%s", want, text)
				}
			}
			for _, want := range testCase.wantReport {
				if !strings.Contains(strings.Join(report, "\n"), want) {
					t.Errorf("report %v missing %q", report, want)
				}
			}
			if testCase.wantReport == nil && len(report) != 0 {
				t.Errorf("unexpected report %v", report)
			}
			loaded, warnings, err := Load(writeFile(t, directory, "config.toml", text))
			if err != nil {
				t.Fatalf("migrated text does not load: %v\n%s", err, text)
			}
			if len(warnings) != 0 {
				t.Errorf("warnings: %v", warnings)
			}
			if !reflect.DeepEqual(loaded, testCase.wantConfig) {
				t.Errorf("got %+v, want %+v\n%s", loaded, testCase.wantConfig, text)
			}
		})
	}
}
