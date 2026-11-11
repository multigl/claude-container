package flavor

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/multigl/claude-container/internal/config"
	"github.com/multigl/claude-container/internal/paths"
)

func testPaths(t *testing.T, flavorName string) paths.Paths {
	t.Helper()
	stateDir := filepath.Join(t.TempDir(), flavorName)
	return paths.Paths{
		Flavor:         flavorName,
		StateDir:       stateDir,
		StateClaudeDir: filepath.Join(stateDir, "claude"),
		HostConfig:     "/cfg/config.toml",
	}
}

func mustNew(t *testing.T, name string) (Flavor, paths.Paths) {
	t.Helper()
	p := testPaths(t, name)
	driver, err := New(name, p)
	if err != nil {
		t.Fatal(err)
	}
	return driver, p
}

func TestNew(t *testing.T) {
	_, err := New("bogus", paths.Paths{})
	if err == nil || !strings.Contains(err.Error(), "gateway personal vertex") {
		t.Fatalf("want error listing known flavors, got %v", err)
	}
	if got := Known(); !reflect.DeepEqual(got, []string{"gateway", "personal", "vertex"}) {
		t.Fatalf("Known() = %v", got)
	}
}

func TestDriverBasics(t *testing.T) {
	tests := []struct {
		name         string
		wantDirs     func(p paths.Paths) []string
		wantPaths    func(p paths.Paths) []string
		wantFlags    func(p paths.Paths) []string
		wantVolume   string
		wantCommand  []string
		wantPrintKey string
	}{
		{
			name:      "vertex",
			wantDirs:  func(p paths.Paths) []string { return []string{p.StateDir + "/creds/gcloud"} },
			wantPaths: func(p paths.Paths) []string { return []string{p.StateDir + "/creds/gcloud"} },
			wantFlags: func(p paths.Paths) []string {
				return []string{"-v", p.StateDir + "/creds/gcloud:/home/claude/.config/gcloud"}
			},
			wantVolume:   "claude-vertex-gcloud",
			wantCommand:  []string{"gcloud", "auth", "application-default", "login", "--no-launch-browser"},
			wantPrintKey: "CRED_GCLOUD_DIR=",
		},
		{
			name:      "gateway",
			wantDirs:  func(p paths.Paths) []string { return []string{p.StateDir + "/creds/okta"} },
			wantPaths: func(p paths.Paths) []string { return []string{p.StateDir + "/creds/okta"} },
			wantFlags: func(p paths.Paths) []string {
				return []string{"-v", p.StateDir + "/creds/okta:/home/claude/.local/share/litellm"}
			},
			wantVolume:   "claude-gateway-okta",
			wantCommand:  []string{"/opt/claude/api-key-helper", "--login-only"},
			wantPrintKey: "CRED_OKTA_DIR=",
		},
		{
			name:         "personal",
			wantDirs:     func(p paths.Paths) []string { return nil },
			wantPaths:    func(p paths.Paths) []string { return []string{p.StateDir + "/claude/.credentials.json"} },
			wantFlags:    func(p paths.Paths) []string { return nil },
			wantVolume:   "",
			wantCommand:  []string{"claude", "auth", "login", "--claudeai"},
			wantPrintKey: "CRED_PERSONAL_FILE=",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			driver, p := mustNew(t, test.name)
			if driver.Name() != test.name {
				t.Errorf("Name() = %q", driver.Name())
			}
			if got := driver.CredDirs(); !reflect.DeepEqual(got, test.wantDirs(p)) {
				t.Errorf("CredDirs() = %v", got)
			}
			if got := driver.CredPaths(); !reflect.DeepEqual(got, test.wantPaths(p)) {
				t.Errorf("CredPaths() = %v", got)
			}
			if got := driver.RunFlags(); !reflect.DeepEqual(got, test.wantFlags(p)) {
				t.Errorf("RunFlags() = %v", got)
			}
			if got := driver.LegacyVolume(); got != test.wantVolume {
				t.Errorf("LegacyVolume() = %q", got)
			}
			command, before, after := driver.AuthCommand()
			if !reflect.DeepEqual(command, test.wantCommand) {
				t.Errorf("AuthCommand() command = %v", command)
			}
			if !strings.HasPrefix(before, ">>") || !strings.HasPrefix(after, ">>") {
				t.Errorf("messages should start with >>: %q %q", before, after)
			}
			if strings.Contains(before+after, "just ") {
				t.Errorf("messages must not mention just: %q %q", before, after)
			}
			printed := driver.PrintPaths()
			if len(printed) != 1 || !strings.HasPrefix(printed[0], test.wantPrintKey) {
				t.Errorf("PrintPaths() = %v", printed)
			}
		})
	}
}

func TestSeedConfig(t *testing.T) {
	tests := []struct {
		name       string
		wantEnv    map[string]string
		absentKeys []string
		wantText   string
	}{
		{
			name: "vertex",
			wantEnv: map[string]string{
				"ANTHROPIC_MODEL":                "claude-opus-5[1m]",
				"CLOUD_ML_REGION":                "us",
				"VERTEX_REGION_CLAUDE_HAIKU_4_5": "us-east5",
			},
			absentKeys: []string{"ANTHROPIC_VERTEX_PROJECT_ID"},
			wantText:   `# ANTHROPIC_VERTEX_PROJECT_ID = "acme-ai-prod"`,
		},
		{
			name: "gateway",
			wantEnv: map[string]string{
				"OKTA_ISSUER":                       "https://YOUR-ORG.okta.com",
				"CLAUDE_CODE_API_KEY_HELPER_TTL_MS": "300000",
			},
			wantText: "[[mounts]]",
		},
		{
			name:       "personal",
			wantEnv:    map[string]string{"CONTEXT7_API_KEY": ""},
			absentKeys: []string{"JIRA_URL"},
			wantText:   "# forward_ssh",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			driver, _ := mustNew(t, test.name)
			seed := driver.SeedConfig()
			path := filepath.Join(t.TempDir(), "config.toml")
			if err := os.WriteFile(path, []byte(seed), 0o600); err != nil {
				t.Fatal(err)
			}
			loaded, warnings, err := config.Load(path)
			if err != nil || len(warnings) != 0 {
				t.Fatalf("Load: err=%v warnings=%v", err, warnings)
			}
			for key, want := range test.wantEnv {
				if got, ok := loaded.Env[key]; !ok || got != want {
					t.Errorf("Env[%s] = %q (present %v), want %q", key, got, ok, want)
				}
			}
			for _, key := range test.absentKeys {
				if _, ok := loaded.Env[key]; ok {
					t.Errorf("Env[%s] should be absent", key)
				}
			}
			if !strings.Contains(seed, test.wantText) {
				t.Errorf("seed missing %q", test.wantText)
			}
			if test.name == "personal" && len(loaded.Env) != 1 {
				t.Errorf("personal Env = %v, want only CONTEXT7_API_KEY", loaded.Env)
			}
		})
	}
}

func TestDoctor(t *testing.T) {
	tests := []struct {
		name   string
		flavor string
		env    map[string]string
		setup  func(t *testing.T, p paths.Paths)
		want   string
	}{
		{"vertex project unset", "vertex", nil, nil, "MISSING PROJECT"},
		{"vertex placeholder", "vertex", map[string]string{"ANTHROPIC_VERTEX_PROJECT_ID": "your-gcp-project"}, nil, "MISSING PROJECT"},
		{"vertex set", "vertex", map[string]string{"ANTHROPIC_VERTEX_PROJECT_ID": "acme"}, nil, "ok: vertex project acme"},
		{"gateway client id empty", "gateway", map[string]string{"OKTA_CLIENT_ID": ""}, nil, "MISSING: set OKTA_CLIENT_ID"},
		{"gateway client id set", "gateway", map[string]string{"OKTA_CLIENT_ID": "abc"}, nil, "ok: OKTA_CLIENT_ID set in /cfg/config.toml"},
		{"personal open directory", "personal", nil, func(t *testing.T, p paths.Paths) {
			if err := os.MkdirAll(p.StateClaudeDir, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.Chmod(p.StateClaudeDir, 0o755); err != nil {
				t.Fatal(err)
			}
		}, "WARN"},
		{"personal missing credential", "personal", nil, nil, "MISSING: run 'claude-personal auth'"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			driver, p := mustNew(t, test.flavor)
			if test.setup != nil {
				test.setup(t, p)
			}
			lines := driver.Doctor(config.Config{Env: test.env})
			joined := strings.Join(lines, "\n")
			if !strings.Contains(joined, test.want) {
				t.Errorf("want %q in:\n%s", test.want, joined)
			}
			for _, line := range lines {
				if !strings.HasPrefix(line, "  ") {
					t.Errorf("line lacks indent: %q", line)
				}
			}
			if strings.Contains(joined, "just ") {
				t.Errorf("doctor mentions just:\n%s", joined)
			}
		})
	}
}
