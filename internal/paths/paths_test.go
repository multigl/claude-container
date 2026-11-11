package paths

import (
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

func environment(values map[string]string) func(string) string {
	return func(name string) string { return values[name] }
}

func TestWorkingDirectory(t *testing.T) {
	realDirectory := t.TempDir()
	linkDirectory := filepath.Join(t.TempDir(), "link")
	if err := os.Symlink(realDirectory, linkDirectory); err != nil {
		t.Fatal(err)
	}
	otherDirectory := t.TempDir()
	t.Chdir(realDirectory)
	expectedFallback, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}

	tests := []struct {
		name     string
		pwd      string
		expected string
	}{
		{"symlink to cwd returned verbatim", linkDirectory, linkDirectory},
		{"unset falls back to Getwd", "", expectedFallback},
		{"stale PWD falls back to Getwd", otherDirectory, expectedFallback},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			actual, err := WorkingDirectory(environment(map[string]string{"PWD": test.pwd}))
			if err != nil {
				t.Fatal(err)
			}
			if actual != test.expected {
				t.Errorf("got %q, want %q", actual, test.expected)
			}
		})
	}
}

func TestPOSIXCksum(t *testing.T) {
	// Expected values come from `printf '%s' "<input>" | cksum`.
	tests := []struct {
		input    string
		expected uint32
	}{
		{"", 4294967295},
		{"/Users/a/b", 2631054986},
		{"/tmp/with space", 3761744265},
		{"/tmp/ünï", 2809603612},
		{"/tmp/trailing/", 1033543359},
	}
	for _, test := range tests {
		t.Run(test.input, func(t *testing.T) {
			if actual := POSIXCksum([]byte(test.input)); actual != test.expected {
				t.Errorf("got %d, want %d", actual, test.expected)
			}
		})
	}
}

func TestProjectKey(t *testing.T) {
	tests := []struct {
		workingDirectory string
	}{
		{"/a/foo-bar/baz"},
		{"/a/foo/bar-baz"},
	}
	keys := map[string]bool{}
	for _, test := range tests {
		t.Run(test.workingDirectory, func(t *testing.T) {
			expected := "-a-foo-bar-baz-" + strconv.FormatUint(uint64(POSIXCksum([]byte(test.workingDirectory))), 10)
			actual := ProjectKey(test.workingDirectory)
			if actual != expected {
				t.Errorf("got %q, want %q", actual, expected)
			}
			keys[actual] = true
		})
	}
	if len(keys) != len(tests) {
		t.Errorf("keys collided: %v", keys)
	}
}

func TestResolve(t *testing.T) {
	tests := []struct {
		name        string
		environment map[string]string
		expected    Paths
	}{
		{
			name:        "XDG unset",
			environment: map[string]string{},
			expected: Paths{
				ConfigDir:      "/home/u/.config/claude-container/personal",
				StateDir:       "/home/u/.local/state/claude-container/personal",
				StateClaudeDir: "/home/u/.local/state/claude-container/personal/claude",
				HostConfig:     "/home/u/.config/claude-container/personal/config.toml",
				HostSettings:   "/home/u/.config/claude-container/personal/settings.override.json",
			},
		},
		{
			name:        "XDG set",
			environment: map[string]string{"XDG_CONFIG_HOME": "/x/config", "XDG_STATE_HOME": "/x/state"},
			expected: Paths{
				ConfigDir:      "/x/config/claude-container/personal",
				StateDir:       "/x/state/claude-container/personal",
				StateClaudeDir: "/x/state/claude-container/personal/claude",
				HostConfig:     "/x/config/claude-container/personal/config.toml",
				HostSettings:   "/x/config/claude-container/personal/settings.override.json",
			},
		},
		{
			name:        "CLAUDE_CONFIG and CLAUDE_SETTINGS overrides",
			environment: map[string]string{"CLAUDE_CONFIG": "/d/config.toml", "CLAUDE_SETTINGS": "/d/settings.json"},
			expected: Paths{
				ConfigDir:      "/home/u/.config/claude-container/personal",
				StateDir:       "/home/u/.local/state/claude-container/personal",
				StateClaudeDir: "/home/u/.local/state/claude-container/personal/claude",
				HostConfig:     "/d/config.toml",
				HostSettings:   "/d/settings.json",
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			actual := Resolve("personal", "/a/foo-bar/baz", "/home/u", environment(test.environment))
			test.expected.Flavor = "personal"
			test.expected.HostDotClaude = test.expected.StateClaudeDir + "/claude.json"
			test.expected.HostDotClaudeLegacy = test.expected.StateDir + "/claude.json"
			test.expected.ProjectKey = ProjectKey("/a/foo-bar/baz")
			test.expected.HostProjectDir = test.expected.StateDir + "/projects/" + test.expected.ProjectKey
			if actual != test.expected {
				t.Errorf("got %+v, want %+v", actual, test.expected)
			}
		})
	}
}
