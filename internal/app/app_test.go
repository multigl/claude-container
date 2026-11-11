package app

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	goruntime "runtime"
	"slices"
	"strings"
	"syscall"
	"testing"

	"github.com/multigl/claude-container/internal/buildinfo"
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
	fakeBin     string
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
		fakeBin:     fakeBin,
		home:        home,
		workspace:   workspace,
		runtimeLog:  runtimeLog,
		environment: map[string]string{"HOME": home, "PATH": fakeBin},
	}
}

func (h *harness) addFakeBinary(t *testing.T, name, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(h.fakeBin, name), []byte(content), 0o755); err != nil {
		t.Fatal(err)
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

type fakeRelease struct {
	server        *httptest.Server
	downloads     int
	authorization string
}

// newFakeRelease answers the latest-release query with tag, or with a 500
// when failing, and counts asset downloads.
func newFakeRelease(t *testing.T, tag string, failing bool, assetBytes []byte) *fakeRelease {
	t.Helper()
	release := &fakeRelease{}
	assetName := "claude-container_" + goruntime.GOOS + "_" + goruntime.GOARCH
	sum := sha256.Sum256(assetBytes)
	mux := http.NewServeMux()
	mux.HandleFunc("/repos/multigl/claude-container/releases/latest", func(writer http.ResponseWriter, request *http.Request) {
		release.authorization = request.Header.Get("Authorization")
		if failing {
			http.Error(writer, "boom", http.StatusInternalServerError)
			return
		}
		fmt.Fprintf(writer, `{"tag_name":%q,"assets":[{"name":%q,"browser_download_url":%q},{"name":"SHA256SUMS","browser_download_url":%q}]}`,
			tag, assetName, release.server.URL+"/download/"+assetName, release.server.URL+"/download/SHA256SUMS")
	})
	mux.HandleFunc("/download/"+assetName, func(writer http.ResponseWriter, request *http.Request) {
		release.downloads++
		writer.Write(assetBytes)
	})
	mux.HandleFunc("/download/SHA256SUMS", func(writer http.ResponseWriter, request *http.Request) {
		fmt.Fprintf(writer, "%s  %s\n", hex.EncodeToString(sum[:]), assetName)
	})
	release.server = httptest.NewServer(mux)
	t.Cleanup(release.server.Close)
	return release
}

type execCall struct {
	binary  string
	argv    []string
	environ []string
}

func TestUpdateFlow(t *testing.T) {
	const pinnedVertex = "ghcr.io/multigl/claude-container:vertex-latest"
	tests := []struct {
		name          string
		version       string
		tag           string
		failing       bool
		readOnly      bool
		environment   map[string]string
		wantCode      int
		wantDownloads int
		wantExec      bool
		wantPull      bool
		wantStdout    string
		wantStderr    string
		wantBinary    string
	}{
		{
			name:       "same tag: no download, then a pull",
			version:    "v1.0.0",
			tag:        "v1.0.0",
			wantPull:   true,
			wantBinary: "old binary",
		},
		{
			name:       "release check fails: exit 1 and no pull",
			version:    "v1.0.0",
			failing:    true,
			wantCode:   1,
			wantStderr: "500",
			wantBinary: "old binary",
		},
		{
			name:       "dev build skips self-update",
			version:    "dev",
			tag:        "v2.0.0",
			wantPull:   true,
			wantStdout: "dev build",
			wantBinary: "old binary",
		},
		{
			name:        "already self-updated: no download, then a pull",
			version:     "v1.0.0",
			tag:         "v2.0.0",
			environment: map[string]string{"_CLAUDE_SELFUPDATED": "1"},
			wantPull:    true,
			wantBinary:  "old binary",
		},
		{
			name:          "differing tag: replaces the binary and re-execs",
			version:       "v1.0.0",
			tag:           "v2.0.0",
			wantDownloads: 1,
			wantExec:      true,
			wantBinary:    "new binary",
		},
		{
			name:       "install directory not writable: prints install.sh and pulls",
			version:    "v1.0.0",
			tag:        "v2.0.0",
			readOnly:   true,
			wantPull:   true,
			wantStderr: "curl -fsSL https://raw.githubusercontent.com/multigl/claude-container/main/install.sh | bash",
			wantBinary: "old binary",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if test.readOnly && os.Geteuid() == 0 {
				t.Skip("root ignores directory permissions")
			}
			h := newHarness(t)
			release := newFakeRelease(t, test.tag, test.failing, []byte("new binary"))

			installDirectory := t.TempDir()
			realBinary := filepath.Join(installDirectory, "claude-container")
			if err := os.WriteFile(realBinary, []byte("old binary"), 0o755); err != nil {
				t.Fatal(err)
			}
			symlink := filepath.Join(t.TempDir(), "claude-vertex")
			if err := os.Symlink(realBinary, symlink); err != nil {
				t.Fatal(err)
			}
			if test.readOnly {
				if err := os.Chmod(installDirectory, 0o555); err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { os.Chmod(installDirectory, 0o755) })
			}

			var calls []execCall
			originalVersion, originalAPIBase, originalExecutable, originalExec := buildinfo.Version, apiBase, executablePath, execBinary
			t.Cleanup(func() {
				buildinfo.Version, apiBase, executablePath, execBinary = originalVersion, originalAPIBase, originalExecutable, originalExec
			})
			buildinfo.Version = test.version
			apiBase = release.server.URL
			executablePath = func() (string, error) { return symlink, nil }
			execBinary = func(binary string, argv []string, environ []string) error {
				calls = append(calls, execCall{binary, argv, environ})
				return nil
			}

			got := h.invoke("claude-vertex", []string{"update"}, test.environment)

			if got.code != test.wantCode {
				t.Errorf("exit %d, want %d; stderr: %s", got.code, test.wantCode, got.stderr)
			}
			if release.downloads != test.wantDownloads {
				t.Errorf("%d downloads, want %d", release.downloads, test.wantDownloads)
			}
			if (len(calls) > 0) != test.wantExec {
				t.Errorf("exec calls %v, want exec %v", calls, test.wantExec)
			}
			if test.wantExec && len(calls) > 0 {
				realBinary, _ := filepath.EvalSymlinks(realBinary)
				wantArgv := []string{"claude-vertex", "update"}
				if calls[0].binary != realBinary || !slices.Equal(calls[0].argv, wantArgv) {
					t.Errorf("exec %s %v, want %s %v", calls[0].binary, calls[0].argv, realBinary, wantArgv)
				}
			}
			if pulled := h.runtimeGot(t, "pull "+pinnedVertex); pulled != test.wantPull {
				t.Errorf("pulled %v, want %v: %v", pulled, test.wantPull, h.runtimeCalls(t))
			}
			if test.wantStdout != "" {
				assertContains(t, "stdout", got.stdout, test.wantStdout)
			}
			if test.wantStderr != "" {
				assertContains(t, "stderr", got.stderr, test.wantStderr)
			}
			if content := readFile(t, realBinary); content != test.wantBinary {
				t.Errorf("binary holds %q, want %q", content, test.wantBinary)
			}
		})
	}
}

func TestReexecArgs(t *testing.T) {
	tests := []struct {
		name    string
		environ []string
	}{
		{"marker absent", []string{"HOME=/home/me", "PATH=/bin"}},
		{"marker already present", []string{"HOME=/home/me", "_CLAUDE_SELFUPDATED=0", "PATH=/bin"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			binary, argv, environ := reexecArgs("/opt/claude-container", []string{"claude-vertex", "update"}, test.environ)
			if binary != "/opt/claude-container" {
				t.Errorf("binary %q", binary)
			}
			if !slices.Equal(argv, []string{"claude-vertex", "update"}) {
				t.Errorf("argv %v", argv)
			}
			markers := 0
			for _, entry := range environ {
				if strings.HasPrefix(entry, "_CLAUDE_SELFUPDATED=") {
					markers++
					if entry != "_CLAUDE_SELFUPDATED=1" {
						t.Errorf("marker %q", entry)
					}
				}
			}
			if markers != 1 {
				t.Errorf("%d markers in %v, want 1", markers, environ)
			}
			if !slices.Contains(environ, "HOME=/home/me") || !slices.Contains(environ, "PATH=/bin") {
				t.Errorf("environment lost entries: %v", environ)
			}
		})
	}
}

const fakeGitHubCLIScript = `#!/bin/sh
[ "$1 $2" = "auth token" ] && echo gho_from_keyring
`

func TestSelfUpdateToken(t *testing.T) {
	tests := []struct {
		name              string
		installGitHubCLI  bool
		environment       map[string]string
		wantAuthorization string
	}{
		{"GH_TOKEN wins over gh", true, map[string]string{"GH_TOKEN": "gho_from_env"}, "Bearer gho_from_env"},
		{"falls back to gh auth token", true, nil, "Bearer gho_from_keyring"},
		{"no token anywhere sends none", false, nil, ""},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			h := newHarness(t)
			if test.installGitHubCLI {
				h.addFakeBinary(t, "gh", fakeGitHubCLIScript)
			}
			release := newFakeRelease(t, "v1.0.0", false, []byte("binary"))
			originalVersion, originalAPIBase := buildinfo.Version, apiBase
			t.Cleanup(func() { buildinfo.Version, apiBase = originalVersion, originalAPIBase })
			buildinfo.Version = "v1.0.0"
			apiBase = release.server.URL

			got := h.invoke("claude-vertex", []string{"update"}, test.environment)

			if got.code != 0 {
				t.Fatalf("exit %d, stderr: %s", got.code, got.stderr)
			}
			if release.authorization != test.wantAuthorization {
				t.Errorf("Authorization %q, want %q", release.authorization, test.wantAuthorization)
			}
		})
	}
}

func TestLaunchGitHubToken(t *testing.T) {
	tests := []struct {
		name             string
		installGitHubCLI bool
		wantFlag         bool
		wantChildToken   string
	}{
		{"token passed by name, value via environment", true, true, "gho_from_keyring"},
		{"no gh, no token", false, false, ""},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			h := newHarness(t)
			t.Setenv("GH_TOKEN", "")
			if test.installGitHubCLI {
				h.addFakeBinary(t, "gh", fakeGitHubCLIScript)
			}
			tokenLog := filepath.Join(t.TempDir(), "token.log")
			h.addFakeBinary(t, "docker", fmt.Sprintf("#!/bin/sh\nprintf '%%s\\n' \"$*\" >> '%s'\nprintf '%%s' \"$GH_TOKEN\" > '%s'\n", h.runtimeLog, tokenLog))

			got := h.invoke("claude-personal", nil, nil)

			if got.code != 0 {
				t.Fatalf("exit %d, stderr: %s", got.code, got.stderr)
			}
			var runCall string
			for _, call := range h.runtimeCalls(t) {
				if strings.HasPrefix(call, "run ") {
					runCall = call
				}
			}
			if hasFlag := strings.Contains(runCall, " -e GH_TOKEN "); hasFlag != test.wantFlag {
				t.Errorf("-e GH_TOKEN present %v, want %v: %s", hasFlag, test.wantFlag, runCall)
			}
			if strings.Contains(runCall, "gho_from_keyring") {
				t.Errorf("token value on argv: %s", runCall)
			}
			if childToken := readFile(t, tokenLog); childToken != test.wantChildToken {
				t.Errorf("runtime saw GH_TOKEN=%q, want %q", childToken, test.wantChildToken)
			}
			stages, _ := filepath.Glob(filepath.Join(h.home, ".local", "state", "claude-container", "personal", ".stage.*"))
			if len(stages) != 0 {
				t.Errorf("stage left behind: %v", stages)
			}
		})
	}
}

func TestInterruptedExitCode(t *testing.T) {
	tests := []struct {
		name    string
		pending []os.Signal
		want    int
	}{
		{"nothing pending", nil, 0},
		{"SIGINT during stage assembly", []os.Signal{syscall.SIGINT}, 130},
		{"SIGHUP during stage assembly", []os.Signal{syscall.SIGHUP}, 129},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			signals := make(chan os.Signal, 1)
			for _, pending := range test.pending {
				signals <- pending
			}
			if got := interruptedExitCode(signals); got != test.want {
				t.Errorf("got %d, want %d", got, test.want)
			}
		})
	}
}
