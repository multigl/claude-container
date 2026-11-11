package app

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeRuntimeScript answers `info` (so detection sees docker as functional)
// and records every invocation's argv, one line per call.
const fakeRuntimeScript = `#!/bin/sh
printf '%s\n' "$*" >> '@LOG@'
exit 0
`

const fakeUnameScript = `#!/bin/sh
if [ "$1" = "-m" ]; then echo x86_64; else echo Linux; fi
`

type harness struct {
	home        string
	workspace   string
	runtimeLog  string
	environment map[string]string
}

type result struct {
	code   int
	stdout string
	stderr string
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	home := t.TempDir()
	workspace := t.TempDir()
	fakeBin := t.TempDir()
	runtimeLog := filepath.Join(t.TempDir(), "runtime.log")
	scripts := map[string]string{
		"docker": strings.ReplaceAll(fakeRuntimeScript, "@LOG@", runtimeLog),
		"uname":  fakeUnameScript,
	}
	for name, content := range scripts {
		if err := os.WriteFile(filepath.Join(fakeBin, name), []byte(content), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	// Child processes (the runtime, gh, git) and exec.LookPath read the real
	// process environment, so it has to agree with the environ passed in.
	t.Setenv("PATH", fakeBin)
	t.Setenv("HOME", home)
	t.Chdir(workspace)
	return &harness{
		home:        home,
		workspace:   workspace,
		runtimeLog:  runtimeLog,
		environment: map[string]string{"HOME": home, "PATH": fakeBin},
	}
}

func (h *harness) configDir(flavorName string) string {
	return filepath.Join(h.home, ".config", "claude-container", flavorName)
}

func (h *harness) writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func (h *harness) invoke(argv0 string, arguments []string, extraEnvironment map[string]string) result {
	var environ []string
	for key, value := range h.environment {
		if _, overridden := extraEnvironment[key]; !overridden {
			environ = append(environ, key+"="+value)
		}
	}
	for key, value := range extraEnvironment {
		environ = append(environ, key+"="+value)
	}
	var stdout, stderr bytes.Buffer
	code := run(append([]string{argv0}, arguments...), environ, &stdout, &stderr)
	return result{code: code, stdout: stdout.String(), stderr: stderr.String()}
}

func (h *harness) runtimeCalls(t *testing.T) []string {
	t.Helper()
	content, err := os.ReadFile(h.runtimeLog)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(strings.TrimRight(string(content), "\n"), "\n")
}

func (h *harness) runtimeGot(t *testing.T, prefix string) bool {
	t.Helper()
	for _, call := range h.runtimeCalls(t) {
		if strings.HasPrefix(call, prefix) {
			return true
		}
	}
	return false
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(content)
}

func assertContains(t *testing.T, label, text, want string) {
	t.Helper()
	if !strings.Contains(text, want) {
		t.Errorf("%s does not contain %q:\n%s", label, want, text)
	}
}

func assertExists(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Stat(path); err != nil {
		t.Errorf("expected %s to exist: %v", path, err)
	}
}

func assertMissing(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Errorf("expected %s not to exist (err=%v)", path, err)
	}
}

func TestRun(t *testing.T) {
	const pinnedPersonal = "ghcr.io/multigl/claude-container:personal-latest"
	cases := []struct {
		name        string
		argv0       string
		arguments   []string
		environment func(h *harness) map[string]string
		setup       func(t *testing.T, h *harness)
		check       func(t *testing.T, h *harness, got result)
	}{
		{
			name:      "print-paths has no side effects",
			argv0:     "claude-vertex",
			arguments: []string{"--print-paths"},
			check: func(t *testing.T, h *harness, got result) {
				if got.code != 0 {
					t.Fatalf("exit %d, stderr: %s", got.code, got.stderr)
				}
				assertContains(t, "stdout", got.stdout, "FLAVOR=vertex\n")
				assertContains(t, "stdout", got.stdout, "HOST_CONFIG="+filepath.Join(h.configDir("vertex"), "config.toml")+"\n")
				assertMissing(t, filepath.Join(h.home, ".config"))
				assertMissing(t, filepath.Join(h.home, ".local"))
			},
		},
		{
			name:        "unknown flavor is a hard error",
			argv0:       "claude-personal",
			environment: func(*harness) map[string]string { return map[string]string{"CLAUDE_FLAVOR": "nope"} },
			check: func(t *testing.T, h *harness, got result) {
				if got.code != 2 {
					t.Errorf("exit %d, want 2", got.code)
				}
				assertContains(t, "stderr", got.stderr, "known flavors: gateway personal vertex")
			},
		},
		{
			name:  "fresh home seeds config.toml and runs",
			argv0: "claude-personal",
			check: func(t *testing.T, h *harness, got result) {
				if got.code != 0 {
					t.Fatalf("exit %d, stderr: %s", got.code, got.stderr)
				}
				info, err := os.Stat(filepath.Join(h.configDir("personal"), "config.toml"))
				if err != nil {
					t.Fatal(err)
				}
				if info.Mode().Perm() != 0o600 {
					t.Errorf("config.toml mode %v, want 0600", info.Mode().Perm())
				}
				if !h.runtimeGot(t, "run ") {
					t.Errorf("runtime never got run: %v", h.runtimeCalls(t))
				}
			},
		},
		{
			name:  "legacy env without config.toml refuses a launch",
			argv0: "claude-personal",
			setup: func(t *testing.T, h *harness) {
				h.writeFile(t, filepath.Join(h.configDir("personal"), "env"), "FOO=bar\n")
			},
			check: func(t *testing.T, h *harness, got result) {
				if got.code != 2 {
					t.Errorf("exit %d, want 2", got.code)
				}
				assertContains(t, "stderr", got.stderr, "claude-personal update")
				if h.runtimeGot(t, "run ") {
					t.Errorf("runtime was invoked: %v", h.runtimeCalls(t))
				}
				assertMissing(t, filepath.Join(h.configDir("personal"), "config.toml"))
			},
		},
		{
			name:      "doctor reports legacy config instead of refusing",
			argv0:     "claude-personal",
			arguments: []string{"doctor"},
			setup: func(t *testing.T, h *harness) {
				h.writeFile(t, filepath.Join(h.configDir("personal"), "env"), "FOO=bar\n")
			},
			check: func(t *testing.T, h *harness, got result) {
				if got.code != 0 {
					t.Errorf("exit %d, stderr: %s", got.code, got.stderr)
				}
				assertContains(t, "stdout", got.stdout, "legacy config")
				assertContains(t, "stdout", got.stdout, "== memory (personal) ==")
				assertMissing(t, filepath.Join(h.configDir("personal"), "config.toml"))
			},
		},
		{
			name:      "reset-auth is not refused by legacy config",
			argv0:     "claude-personal",
			arguments: []string{"reset-auth"},
			setup: func(t *testing.T, h *harness) {
				h.writeFile(t, filepath.Join(h.configDir("personal"), "env"), "FOO=bar\n")
			},
			check: func(t *testing.T, h *harness, got result) {
				if got.code != 0 {
					t.Errorf("exit %d, stderr: %s", got.code, got.stderr)
				}
			},
		},
		{
			name:  "CLAUDE_ENV_FILE naming an existing file counts as legacy",
			argv0: "claude-personal",
			environment: func(h *harness) map[string]string {
				return map[string]string{"CLAUDE_ENV_FILE": filepath.Join(h.home, "dotfiles", "env")}
			},
			setup: func(t *testing.T, h *harness) {
				h.writeFile(t, filepath.Join(h.home, "dotfiles", "env"), "FOO=bar\n")
			},
			check: func(t *testing.T, h *harness, got result) {
				if got.code != 2 {
					t.Errorf("exit %d, want 2; stderr: %s", got.code, got.stderr)
				}
			},
		},
		{
			name:  "CLAUDE_CONFIG naming a missing file is an error",
			argv0: "claude-personal",
			environment: func(h *harness) map[string]string {
				return map[string]string{"CLAUDE_CONFIG": filepath.Join(h.home, "dotfiles", "config.toml")}
			},
			check: func(t *testing.T, h *harness, got result) {
				if got.code != 1 {
					t.Errorf("exit %d, want 1", got.code)
				}
				assertContains(t, "stderr", got.stderr, filepath.Join(h.home, "dotfiles", "config.toml"))
				assertMissing(t, filepath.Join(h.home, "dotfiles", "config.toml"))
			},
		},
		{
			name:  "config.toml wins over legacy files with a warning",
			argv0: "claude-personal",
			setup: func(t *testing.T, h *harness) {
				h.writeFile(t, filepath.Join(h.configDir("personal"), "config.toml"), "[env]\nFOO = \"bar\"\n")
				h.writeFile(t, filepath.Join(h.configDir("personal"), "mounts"), "~/notes\n")
			},
			check: func(t *testing.T, h *harness, got result) {
				if got.code != 0 {
					t.Fatalf("exit %d, stderr: %s", got.code, got.stderr)
				}
				assertContains(t, "stderr", got.stderr, "legacy files ignored")
				if !h.runtimeGot(t, "run ") {
					t.Errorf("runtime never got run: %v", h.runtimeCalls(t))
				}
			},
		},
		{
			name:      "update migrates legacy files and pulls the pinned image",
			argv0:     "claude-personal",
			arguments: []string{"update"},
			setup: func(t *testing.T, h *harness) {
				h.writeFile(t, filepath.Join(h.configDir("personal"), "env"), "FOO=bar\n")
				h.writeFile(t, filepath.Join(h.configDir("personal"), "launcher.conf"), "forward_ssh = yes\n")
			},
			check: func(t *testing.T, h *harness, got result) {
				if got.code != 0 {
					t.Fatalf("exit %d, stderr: %s", got.code, got.stderr)
				}
				migrated := readFile(t, filepath.Join(h.configDir("personal"), "config.toml"))
				assertContains(t, "config.toml", migrated, `FOO = "bar"`)
				assertContains(t, "config.toml", migrated, "forward_ssh = true")
				assertExists(t, filepath.Join(h.configDir("personal"), "env"))
				assertExists(t, filepath.Join(h.configDir("personal"), "launcher.conf"))
				assertContains(t, "stdout", got.stdout, filepath.Join(h.configDir("personal"), "env"))
				assertContains(t, "stdout", got.stdout, filepath.Join(h.configDir("personal"), "launcher.conf"))
				assertContains(t, "stdout", got.stdout, "delete the old files")
				if !h.runtimeGot(t, "pull "+pinnedPersonal) {
					t.Errorf("runtime never pulled %s: %v", pinnedPersonal, h.runtimeCalls(t))
				}
			},
		},
		{
			name:        "update warns when an image override is active",
			argv0:       "claude-personal",
			arguments:   []string{"update"},
			environment: func(*harness) map[string]string { return map[string]string{"CLAUDE_IMAGE": "x"} },
			check: func(t *testing.T, h *harness, got result) {
				if got.code != 0 {
					t.Fatalf("exit %d, stderr: %s", got.code, got.stderr)
				}
				assertContains(t, "stderr", got.stderr, "image override active")
			},
		},
		{
			name:      "update writes the migrated config to CLAUDE_CONFIG",
			argv0:     "claude-personal",
			arguments: []string{"update"},
			environment: func(h *harness) map[string]string {
				return map[string]string{"CLAUDE_CONFIG": filepath.Join(h.home, "dotfiles", "config.toml")}
			},
			setup: func(t *testing.T, h *harness) {
				h.writeFile(t, filepath.Join(h.configDir("personal"), "env"), "FOO=bar\n")
			},
			check: func(t *testing.T, h *harness, got result) {
				if got.code != 0 {
					t.Fatalf("exit %d, stderr: %s", got.code, got.stderr)
				}
				assertContains(t, "config.toml", readFile(t, filepath.Join(h.home, "dotfiles", "config.toml")), `FOO = "bar"`)
				assertMissing(t, filepath.Join(h.configDir("personal"), "config.toml"))
			},
		},
		{
			name:      "update leaves an existing config.toml alone",
			argv0:     "claude-personal",
			arguments: []string{"update"},
			setup: func(t *testing.T, h *harness) {
				h.writeFile(t, filepath.Join(h.configDir("personal"), "config.toml"), "# mine\n")
				h.writeFile(t, filepath.Join(h.configDir("personal"), "env"), "FOO=bar\n")
			},
			check: func(t *testing.T, h *harness, got result) {
				if got.code != 0 {
					t.Fatalf("exit %d, stderr: %s", got.code, got.stderr)
				}
				if content := readFile(t, filepath.Join(h.configDir("personal"), "config.toml")); content != "# mine\n" {
					t.Errorf("config.toml was rewritten:\n%s", content)
				}
			},
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			h := newHarness(t)
			if testCase.setup != nil {
				testCase.setup(t, h)
			}
			var extraEnvironment map[string]string
			if testCase.environment != nil {
				extraEnvironment = testCase.environment(h)
			}
			testCase.check(t, h, h.invoke(testCase.argv0, testCase.arguments, extraEnvironment))
		})
	}
}
