package launch

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/multigl/claude-container/internal/config"
	"github.com/multigl/claude-container/internal/flavor"
	"github.com/multigl/claude-container/internal/paths"
	"github.com/multigl/claude-container/internal/runtime"
)

func newTestPaths(t *testing.T) paths.Paths {
	t.Helper()
	stateDir := t.TempDir()
	return paths.Paths{
		Flavor:         "personal",
		ConfigDir:      t.TempDir(),
		StateDir:       stateDir,
		StateClaudeDir: filepath.Join(stateDir, "claude"),
		ProjectKey:     "-work-repo-123",
		HostProjectDir: filepath.Join(stateDir, "projects", "-work-repo-123"),
		HostSettings:   filepath.Join(t.TempDir(), "settings.override.json"),
	}
}

func TestBuildArgs(t *testing.T) {
	const secretToken = "gho_secret_value"
	testCases := []struct {
		name          string
		gitHubToken   string
		wantTokenFlag []string
	}{
		{"token passed by name only", secretToken, []string{"-e", "GH_TOKEN"}},
		{"no token, no flag", "", nil},
	}
	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			p := newTestPaths(t)
			home := t.TempDir()
			notes := filepath.Join(home, "notes")
			if err := os.MkdirAll(notes, 0o755); err != nil {
				t.Fatal(err)
			}
			dockerRuntime, err := runtime.New("docker")
			if err != nil {
				t.Fatal(err)
			}
			personalFlavor, err := flavor.New("personal", p)
			if err != nil {
				t.Fatal(err)
			}
			stage := Stage{Dir: filepath.Join(p.StateDir, ".stage.abc123"), EnvFile: filepath.Join(p.StateDir, ".stage.abc123.env")}
			options := RunOptions{
				Paths:            p,
				Config:           config.Config{ForwardSSH: true, DNS: []string{"1.1.1.1"}, Mounts: []config.Mount{{Path: "~/notes"}}},
				Runtime:          dockerRuntime,
				Flavor:           personalFlavor,
				Stage:            stage,
				Image:            "ghcr.io/multigl/claude-container:personal-latest",
				Getenv:           getenvFrom(map[string]string{"SSH_AUTH_SOCK": "/tmp/agent.sock"}),
				Host:             runtime.Host{OS: "Linux", Arch: "x86_64"},
				UID:              501,
				GID:              20,
				TTY:              true,
				Reseed:           true,
				Command:          []string{"claude", "--resume"},
				WorkingDirectory: "/work/repo",
				Home:             home,
				GitHubToken:      testCase.gitHubToken,
			}

			args, warnings := BuildArgs(options)

			want := []string{
				"docker", "run", "--rm",
				"-it",
				"-v", stage.Dir + ":/opt/claude-stage:ro",
			}
			want = append(want, testCase.wantTokenFlag...)
			want = append(want,
				"-e", "CLAUDE_RESEED=1",
				"-v", notes+":/mnt/approved/notes:ro",
				"-v", "/tmp/agent.sock:/ssh-agent", "-e", "SSH_AUTH_SOCK=/ssh-agent",
				"--dns", "1.1.1.1",
				"--env-file", stage.EnvFile,
				"-e", "HOST_UID=501",
				"-e", "HOST_GID=20",
				"-e", "CLAUDE_HOST_DIR=/work/repo",
				"-v", "/work/repo:/workspace",
				"-v", p.StateClaudeDir+":/home/claude/.claude",
				"-v", p.HostProjectDir+":/home/claude/.claude/projects/-workspace",
				"-w", "/workspace",
				"ghcr.io/multigl/claude-container:personal-latest",
				"claude", "--resume",
			)
			if !reflect.DeepEqual(args, want) {
				t.Fatalf("argv mismatch\n got: %q\nwant: %q", args, want)
			}
			if len(warnings) != 0 {
				t.Fatalf("unexpected warnings: %v", warnings)
			}
			if strings.Contains(strings.Join(args, " "), secretToken) {
				t.Fatalf("token value leaked onto the argv: %q", args)
			}
		})
	}
}

func TestRunOptionsEnvironment(t *testing.T) {
	testCases := []struct {
		name        string
		gitHubToken string
		want        []string
	}{
		{"token set", "gho_secret", []string{"GH_TOKEN=gho_secret"}},
		{"token unset", "", nil},
	}
	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			if got := (RunOptions{GitHubToken: testCase.gitHubToken}).Environment(); !reflect.DeepEqual(got, testCase.want) {
				t.Fatalf("got %q, want %q", got, testCase.want)
			}
		})
	}
}

func TestBuildArgsSSHWarnings(t *testing.T) {
	dockerRuntime, err := runtime.New("docker")
	if err != nil {
		t.Fatal(err)
	}
	testCases := []struct {
		name        string
		host        runtime.Host
		environment map[string]string
		wantWarning string
	}{
		{"supported but no agent", runtime.Host{OS: "Linux"}, map[string]string{"CLAUDE_FORWARD_SSH": "1"},
			">> SSH forwarding enabled but SSH_AUTH_SOCK is unset (no agent running?); skipping."},
		{"unsupported on Docker Desktop", runtime.Host{OS: "Darwin"}, map[string]string{"CLAUDE_FORWARD_SSH": "1", "SSH_AUTH_SOCK": "/tmp/agent.sock"},
			">> SSH forwarding unsupported on docker for this host; use apple `container` or push over HTTPS. Skipping."},
	}
	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			p := newTestPaths(t)
			personalFlavor, err := flavor.New("personal", p)
			if err != nil {
				t.Fatal(err)
			}
			args, warnings := BuildArgs(RunOptions{
				Paths: p, Runtime: dockerRuntime, Flavor: personalFlavor, Getenv: getenvFrom(testCase.environment),
				Host: testCase.host, Image: "image", WorkingDirectory: "/work/repo",
			})
			if !reflect.DeepEqual(warnings, []string{testCase.wantWarning}) {
				t.Fatalf("got warnings %q, want %q", warnings, testCase.wantWarning)
			}
			if strings.Contains(strings.Join(args, " "), "SSH_AUTH_SOCK") {
				t.Fatalf("ssh flags present despite warning: %q", args)
			}
		})
	}
}

func setModificationTime(t *testing.T, path string, age time.Duration) {
	t.Helper()
	moment := time.Now().Add(-age)
	if err := os.Chtimes(path, moment, moment); err != nil {
		t.Fatal(err)
	}
}

func TestNewStage(t *testing.T) {
	testCases := []struct {
		name               string
		writeSettings      bool
		wantSettingsStaged bool
	}{
		{"missing settings override is not staged", false, false},
		{"existing settings override is staged", true, true},
	}
	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			p := newTestPaths(t)
			home := t.TempDir()
			workingDirectory := t.TempDir()
			if testCase.writeSettings {
				if err := os.WriteFile(p.HostSettings, []byte(`{"model":"x"}`), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			oldDir := filepath.Join(p.StateDir, ".stage.old")
			oldEnvFile := oldDir + ".env"
			freshDir := filepath.Join(p.StateDir, ".stage.new")
			for _, directory := range []string{oldDir, freshDir} {
				if err := os.Mkdir(directory, 0o700); err != nil {
					t.Fatal(err)
				}
			}
			if err := os.WriteFile(oldEnvFile, []byte("A=1\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			setModificationTime(t, oldDir, 48*time.Hour)
			setModificationTime(t, oldEnvFile, 48*time.Hour)

			stage, _, err := NewStage(p, config.Config{Env: map[string]string{"FOO": "bar"}}, home, workingDirectory)
			if err != nil {
				t.Fatal(err)
			}

			_, statError := os.Stat(filepath.Join(stage.Dir, "settings.override.json"))
			if staged := statError == nil; staged != testCase.wantSettingsStaged {
				t.Fatalf("settings staged = %v, want %v", staged, testCase.wantSettingsStaged)
			}
			if _, err := os.Stat(filepath.Join(stage.Dir, "gitconfig-identity")); err != nil {
				t.Fatalf("gitconfig-identity not written: %v", err)
			}
			info, err := os.Stat(stage.EnvFile)
			if err != nil {
				t.Fatal(err)
			}
			if mode := info.Mode().Perm(); mode != 0o600 {
				t.Fatalf("env file mode %o, want 600", mode)
			}
			if stage.EnvFile != stage.Dir+".env" || filepath.Dir(stage.EnvFile) != p.StateDir {
				t.Fatalf("env file %s should be the sibling of %s", stage.EnvFile, stage.Dir)
			}
			content, err := os.ReadFile(stage.EnvFile)
			if err != nil {
				t.Fatal(err)
			}
			if string(content) != "FOO=bar\n" {
				t.Fatalf("env file content %q", content)
			}
			for _, swept := range []string{oldDir, oldEnvFile} {
				if _, err := os.Stat(swept); !os.IsNotExist(err) {
					t.Fatalf("%s should have been swept", swept)
				}
			}
			if _, err := os.Stat(freshDir); err != nil {
				t.Fatalf("fresh stage dir should be kept: %v", err)
			}

			stage.Remove()
			for _, removed := range []string{stage.Dir, stage.EnvFile} {
				if _, err := os.Stat(removed); !os.IsNotExist(err) {
					t.Fatalf("%s should have been removed", removed)
				}
			}
		})
	}
}

func TestNewStageCopiesHostFiles(t *testing.T) {
	p := newTestPaths(t)
	home := t.TempDir()
	if err := os.MkdirAll(filepath.Join(home, ".claude"), 0o755); err != nil {
		t.Fatal(err)
	}
	hostFiles := map[string]string{
		filepath.Join(home, ".claude.json"):                     "host-claude.json",
		filepath.Join(home, ".claude", "statusline-command.sh"): "statusline.sh",
	}
	for source := range hostFiles {
		if err := os.WriteFile(source, []byte(source), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	stage, _, err := NewStage(p, config.Config{}, home, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer stage.Remove()
	for source, stagedName := range hostFiles {
		content, err := os.ReadFile(filepath.Join(stage.Dir, stagedName))
		if err != nil || string(content) != source {
			t.Fatalf("%s: got %q, %v", stagedName, content, err)
		}
	}
}

func TestNewStageEnvironment(t *testing.T) {
	testCases := []struct {
		name        string
		configured  map[string]string
		wantContent string
	}{
		{"configured env written", map[string]string{"FOO": "bar", "BAZ": "qux"}, "BAZ=qux\nFOO=bar\n"},
		{"no configured env leaves it empty", nil, ""},
	}
	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			p := newTestPaths(t)
			stage, _, err := NewStage(p, config.Config{Env: testCase.configured}, t.TempDir(), t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			defer stage.Remove()
			info, err := os.Stat(stage.EnvFile)
			if err != nil {
				t.Fatal(err)
			}
			if mode := info.Mode().Perm(); mode != 0o600 {
				t.Fatalf("env file mode %o, want 600", mode)
			}
			content, err := os.ReadFile(stage.EnvFile)
			if err != nil {
				t.Fatal(err)
			}
			if string(content) != testCase.wantContent {
				t.Fatalf("got %q, want %q", content, testCase.wantContent)
			}
			if strings.Contains(string(content), "GH_TOKEN") {
				t.Fatalf("GH_TOKEN must never reach the env file: %q", content)
			}
		})
	}
}

// runWithSignals runs args the way the launcher does, signals registered first.
func runWithSignals(t *testing.T, args []string, extraEnvironment []string) int {
	t.Helper()
	signals, stop := NotifySignals()
	defer stop()
	return Run(args, extraEnvironment, signals)
}

func TestRunExitCode(t *testing.T) {
	testCases := []struct {
		name     string
		args     []string
		wantCode int
	}{
		{"success", []string{"sh", "-c", "exit 0"}, 0},
		{"child exit code passed through", []string{"sh", "-c", "exit 7"}, 7},
		{"killed by signal", []string{"sh", "-c", "kill -TERM $$"}, 143},
		{"missing binary", []string{"/nonexistent/claude-container-runtime"}, 127},
	}
	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			if code := runWithSignals(t, testCase.args, nil); code != testCase.wantCode {
				t.Fatalf("got %d, want %d", code, testCase.wantCode)
			}
		})
	}
}

func TestRunEnvironment(t *testing.T) {
	testCases := []struct {
		name             string
		extraEnvironment []string
		wantToken        string
	}{
		{"token reaches the child", []string{"GH_TOKEN=gho_secret"}, "gho_secret"},
		{"no extra environment", nil, ""},
	}
	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			t.Setenv("GH_TOKEN", "")
			directory := t.TempDir()
			outputFile := filepath.Join(directory, "token")
			script := filepath.Join(directory, "fake-runtime")
			if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf '%s' \"$GH_TOKEN\" > \"$1\"\n"), 0o755); err != nil {
				t.Fatal(err)
			}
			if code := runWithSignals(t, []string{script, outputFile}, testCase.extraEnvironment); code != 0 {
				t.Fatalf("exit %d", code)
			}
			content, err := os.ReadFile(outputFile)
			if err != nil {
				t.Fatal(err)
			}
			if string(content) != testCase.wantToken {
				t.Fatalf("child saw GH_TOKEN=%q, want %q", content, testCase.wantToken)
			}
		})
	}
}

func TestRunSignal(t *testing.T) {
	testCases := []struct {
		name     string
		signal   syscall.Signal
		trapName string
		wantCode int
	}{
		{"SIGINT relayed", syscall.SIGINT, "INT", 130},
		{"SIGTERM relayed", syscall.SIGTERM, "TERM", 143},
		{"SIGHUP relayed", syscall.SIGHUP, "HUP", 129},
		{"SIGQUIT relayed", syscall.SIGQUIT, "QUIT", 131},
	}
	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			directory := t.TempDir()
			readyFile := filepath.Join(directory, "ready")
			receivedFile := filepath.Join(directory, "received")
			script := filepath.Join(directory, "fake-runtime")
			scriptBody := fmt.Sprintf("#!/bin/sh\ntrap 'touch \"$2\"; exit %d' %s\ntouch \"$1\"\nwhile :; do sleep 0.05; done\n", testCase.wantCode, testCase.trapName)
			if err := os.WriteFile(script, []byte(scriptBody), 0o755); err != nil {
				t.Fatal(err)
			}
			// Stands in for the caller's deferred stage removal.
			stage := filepath.Join(directory, ".stage.run")
			if err := os.Mkdir(stage, 0o700); err != nil {
				t.Fatal(err)
			}

			go func() {
				deadline := time.Now().Add(10 * time.Second)
				for time.Now().Before(deadline) {
					if _, err := os.Stat(readyFile); err == nil {
						syscall.Kill(os.Getpid(), testCase.signal)
						return
					}
					time.Sleep(20 * time.Millisecond)
				}
			}()

			code := func() int {
				defer os.RemoveAll(stage)
				return runWithSignals(t, []string{script, readyFile, receivedFile}, nil)
			}()

			if code != testCase.wantCode {
				t.Fatalf("got %d, want %d", code, testCase.wantCode)
			}
			if _, err := os.Stat(receivedFile); err != nil {
				t.Fatalf("child never got %s: %v", testCase.trapName, err)
			}
			if _, err := os.Stat(stage); !os.IsNotExist(err) {
				t.Fatalf("cleanup did not run: %v", err)
			}
		})
	}
}
