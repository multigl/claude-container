package config

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

const fullExample = `image = "claude-personal:latest"
forward_ssh = false
dns = ["1.1.1.1", "8.8.8.8"]

[env]
ANTHROPIC_MODEL = "claude-opus-5[1m]"
CONTEXT7_API_KEY = ""

[[mounts]]
path = "~/notes"

[[mounts]]
path = "~/scratch"
rw = true
`

func TestLoad(t *testing.T) {
	testCases := []struct {
		name             string
		content          string
		wantConfig       *Config
		wantWarnings     []string
		wantErrorContain []string
	}{
		{
			name:    "full example",
			content: fullExample,
			wantConfig: &Config{
				Image:      "claude-personal:latest",
				ForwardSSH: false,
				DNS:        []string{"1.1.1.1", "8.8.8.8"},
				Env: map[string]string{
					"ANTHROPIC_MODEL":  "claude-opus-5[1m]",
					"CONTEXT7_API_KEY": "",
				},
				Mounts: []Mount{{Path: "~/notes"}, {Path: "~/scratch", RW: true}},
			},
		},
		{
			name:         "unknown top-level key warns",
			content:      "CLAUDE_FORWARD_SSH = true\n",
			wantWarnings: []string{"unrecognized key 'CLAUDE_FORWARD_SSH'", "forward_ssh"},
		},
		{
			name:         "unknown mount field warns",
			content:      "[[mounts]]\npath = \"/a\"\nreadwrite = true\n",
			wantWarnings: []string{"unrecognized key 'mounts.readwrite'"},
		},
		{
			name:    "unknown key inside env is not a warning",
			content: "[env]\nANYTHING = \"ok\"\n",
			wantConfig: &Config{
				Env: map[string]string{"ANYTHING": "ok"},
			},
		},
		{
			name:             "syntax error names path and line",
			content:          "image = \n",
			wantErrorContain: []string{"config.toml", "line 1"},
		},
		{
			name:             "env value must be a string",
			content:          "[env]\nFOO = 1\n",
			wantErrorContain: []string{"FOO", "string"},
		},
		{
			name:             "env value with newline",
			content:          "[env]\nFOO = \"a\\nb\"\n",
			wantErrorContain: []string{"FOO", "newline"},
		},
		{
			name:             "env key invalid",
			content:          "[env]\n\"1BAD\" = \"x\"\n",
			wantErrorContain: []string{"1BAD"},
		},
	}
	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "config.toml")
			if err := os.WriteFile(path, []byte(testCase.content), 0o600); err != nil {
				t.Fatal(err)
			}
			got, warnings, err := Load(path)
			if len(testCase.wantErrorContain) > 0 {
				if err == nil {
					t.Fatal("expected error, got nil")
				}
				for _, fragment := range testCase.wantErrorContain {
					if !strings.Contains(err.Error(), fragment) {
						t.Errorf("error %q missing %q", err, fragment)
					}
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if testCase.wantConfig != nil && !reflect.DeepEqual(got, *testCase.wantConfig) {
				t.Errorf("config = %#v, want %#v", got, *testCase.wantConfig)
			}
			if len(testCase.wantWarnings) == 0 && len(warnings) != 0 {
				t.Errorf("unexpected warnings: %v", warnings)
			}
			for _, fragment := range testCase.wantWarnings {
				if !strings.Contains(strings.Join(warnings, "\n"), fragment) {
					t.Errorf("warnings %v missing %q", warnings, fragment)
				}
			}
		})
	}
}

func TestLoadMissingFile(t *testing.T) {
	if _, _, err := Load(filepath.Join(t.TempDir(), "absent.toml")); err == nil {
		t.Fatal("expected error for missing file")
	}
}

func TestWriteEnvFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "env")
	if err := WriteEnvFile(path, map[string]string{"B": "", "A": "1"}); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("mode = %v, want 0600", info.Mode().Perm())
	}
	content, _ := os.ReadFile(path)
	if string(content) != "A=1\nB=\n" {
		t.Errorf("content = %q", content)
	}

	verbatimPath := filepath.Join(t.TempDir(), "env")
	if err := WriteEnvFile(verbatimPath, map[string]string{"K": "a#b=c"}); err != nil {
		t.Fatal(err)
	}
	content, _ = os.ReadFile(verbatimPath)
	if string(content) != "K=a#b=c\n" {
		t.Errorf("content = %q", content)
	}
}
