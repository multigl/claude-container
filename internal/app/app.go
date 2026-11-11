// Package app is the launcher's top level: flavor selection, init side
// effects and subcommand dispatch.
package app

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/multigl/claude-container/internal/buildinfo"
	"github.com/multigl/claude-container/internal/config"
	"github.com/multigl/claude-container/internal/flavor"
	"github.com/multigl/claude-container/internal/launch"
	"github.com/multigl/claude-container/internal/paths"
	"github.com/multigl/claude-container/internal/runtime"
)

type app struct {
	argv             []string
	environ          []string
	getenv           func(string) string
	stdout           io.Writer
	stderr           io.Writer
	paths            paths.Paths
	flavor           flavor.Flavor
	home             string
	workingDirectory string
	host             runtime.Host
	runtimeName      string
	runtimeResolved  bool
}

// Main reads its own settings from environ, not the process environment, so
// tests can drive it hermetically. Child processes still inherit the real
// process environment.
func Main(argv []string, environ []string) int {
	return run(argv, environ, os.Stdout, os.Stderr)
}

func getenvFrom(environ []string) func(string) string {
	environment := map[string]string{}
	for _, entry := range environ {
		if key, value, found := strings.Cut(entry, "="); found {
			environment[key] = value
		}
	}
	return func(key string) string { return environment[key] }
}

func flavorFromName(argv0, override string) string {
	if override != "" {
		return override
	}
	switch filepath.Base(argv0) {
	case "claude-vertex":
		return "vertex"
	case "claude-gateway":
		return "gateway"
	}
	return "personal"
}

func run(argv []string, environ []string, stdout, stderr io.Writer) int {
	getenv := getenvFrom(environ)
	a := &app{argv: argv, environ: environ, getenv: getenv, stdout: stdout, stderr: stderr}

	flavorName := flavorFromName(argv[0], getenv("CLAUDE_FLAVOR"))
	known := false
	for _, name := range flavor.Known() {
		known = known || name == flavorName
	}
	if !known {
		fmt.Fprintf(stderr, "!! unknown flavor '%s'\n", flavorName)
		fmt.Fprintf(stderr, "   known flavors: %s\n", strings.Join(flavor.Known(), " "))
		return 2
	}

	a.home = getenv("HOME")
	if a.home == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			fmt.Fprintf(stderr, "!! %v\n", err)
			return 1
		}
		a.home = home
	}
	workingDirectory, err := paths.WorkingDirectory(getenv)
	if err != nil {
		fmt.Fprintf(stderr, "!! %v\n", err)
		return 1
	}
	a.workingDirectory = workingDirectory
	a.paths = paths.Resolve(flavorName, workingDirectory, a.home, getenv)
	a.flavor, err = flavor.New(flavorName, a.paths)
	if err != nil {
		fmt.Fprintf(stderr, "!! %v\n", err)
		return 2
	}

	command, arguments := "", []string(nil)
	if len(argv) > 1 {
		command, arguments = argv[1], argv[2:]
	}
	switch command {
	case "--version":
		fmt.Fprintf(stdout, "claude-container %s (image %s)\n", buildinfo.Version, buildinfo.PinnedImage(flavorName))
		return 0
	case "--print-runtime":
		return a.printRuntime()
	case "--print-paths":
		return a.printPaths()
	}

	if err := a.initialize(); err != nil {
		fmt.Fprintf(stderr, "!! %v\n", err)
		return 1
	}

	switch command {
	case "auth":
		authCommand, before, after := a.flavor.AuthCommand()
		fmt.Fprintln(stdout, before)
		if code := a.runInContainer(authCommand, false); code != 0 {
			return code
		}
		fmt.Fprintln(stdout, after)
		return 0
	case "reseed":
		if code := a.runInContainer([]string{"true"}, true); code != 0 {
			return code
		}
		fmt.Fprintf(stdout, ">> re-seeded %s from image (settings + plugins overwritten)\n", a.paths.StateClaudeDir)
		return 0
	case "rebuild-memory-index":
		if code := a.runInContainer([]string{"true"}, false); code != 0 {
			return code
		}
		fmt.Fprintf(stdout, ">> rebuilt memory indexes for %s (project + global tier)\n", a.paths.ProjectKey)
		return 0
	case "migrate-memory":
		return a.migrateMemory()
	case "migrate-creds":
		return a.migrateCreds()
	case "reset-auth":
		return a.resetAuth()
	case "update":
		return a.update()
	case "doctor":
		return a.doctor()
	case "shell":
		return a.runInContainer(append([]string{"bash"}, arguments...), false)
	case "--":
		return a.runInContainer(append([]string{"claude"}, arguments...), false)
	case "":
		return a.runInContainer([]string{"claude"}, false)
	}
	return a.runInContainer(append([]string{"claude"}, argv[1:]...), false)
}

// resolveRuntime probes lazily: --version and the host-only subcommands never
// need a `docker info` round trip.
func (a *app) resolveRuntime() string {
	if !a.runtimeResolved {
		a.host = runtime.ProbeHost()
		a.runtimeName = runtime.Resolve(a.getenv("CLAUDE_RUNTIME"), a.host)
		a.runtimeResolved = true
	}
	return a.runtimeName
}

func (a *app) requireRuntime() (runtime.Runtime, bool) {
	name := a.resolveRuntime()
	if name == "none" {
		fmt.Fprintln(a.stderr, "!! no usable container runtime found.")
		if override := a.getenv("CLAUDE_RUNTIME"); override != "" {
			fmt.Fprintf(a.stderr, "   CLAUDE_RUNTIME=%s is not installed/functional on this host.\n", override)
		} else {
			fmt.Fprintln(a.stderr, "   install docker or podman (or Apple 'container' on macOS 26+ Apple Silicon).")
		}
		return nil, false
	}
	containerRuntime, err := runtime.New(name)
	if err != nil {
		fmt.Fprintf(a.stderr, "!! %v\n", err)
		return nil, false
	}
	return containerRuntime, true
}

func (a *app) printRuntime() int {
	fmt.Fprintf(a.stdout, "RUNTIME=%s\n", a.resolveRuntime())
	for _, name := range []string{"apple", "docker", "podman"} {
		if runtime.Available(name, a.host) {
			fmt.Fprintf(a.stdout, "available: %s\n", name)
		}
	}
	return 0
}

func (a *app) printPaths() int {
	cfg, err := a.loadConfigIfPresent()
	if err != nil {
		fmt.Fprintf(a.stderr, "!! %v\n", err)
		return 1
	}
	lines := []string{
		"FLAVOR=" + a.paths.Flavor,
		"CFG_DIR=" + a.paths.ConfigDir,
		"STATE_DIR=" + a.paths.StateDir,
		"STATE_CLAUDE_DIR=" + a.paths.StateClaudeDir,
		"HOST_DOTCLAUDE=" + a.paths.HostDotClaude,
		"PROJECT_KEY=" + a.paths.ProjectKey,
		"HOST_PROJECT_DIR=" + a.paths.HostProjectDir,
		"HOST_CONFIG=" + a.paths.HostConfig,
		"HOST_SETTINGS=" + a.paths.HostSettings,
		"IMAGE=" + a.image(cfg),
		"RUNTIME=" + a.resolveRuntime(),
		"VERSION=" + buildinfo.Version,
	}
	for _, line := range append(lines, a.flavor.PrintPaths()...) {
		fmt.Fprintln(a.stdout, line)
	}
	return 0
}

func (a *app) image(cfg config.Config) string {
	if image := a.getenv("CLAUDE_IMAGE"); image != "" {
		return image
	}
	if cfg.Image != "" {
		return cfg.Image
	}
	return buildinfo.PinnedImage(a.paths.Flavor)
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// writeNewPrivateFile never replaces an existing file, so a concurrent
// launch or a user's own config can't be clobbered.
func writeNewPrivateFile(path, content string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	if _, err := file.WriteString(content); err != nil {
		file.Close()
		return err
	}
	return file.Close()
}

func (a *app) initialize() error {
	for _, directory := range []string{a.paths.ConfigDir, a.paths.StateClaudeDir, a.paths.HostProjectDir} {
		if err := os.MkdirAll(directory, 0o755); err != nil {
			return err
		}
	}
	// Re-tightened every launch: the dir holds grafted MCP creds and, for
	// personal, a plaintext OAuth token.
	if err := os.Chmod(a.paths.StateClaudeDir, 0o700); err != nil {
		return err
	}
	if fileExists(a.paths.HostDotClaudeLegacy) && !fileExists(a.paths.HostDotClaude) {
		if err := os.Rename(a.paths.HostDotClaudeLegacy, a.paths.HostDotClaude); err != nil {
			return err
		}
	}
	if !fileExists(a.paths.HostDotClaude) {
		if err := os.WriteFile(a.paths.HostDotClaude, nil, 0o600); err != nil {
			return err
		}
	}
	// Never seed into a CLAUDE_CONFIG path (usually a dotfiles repo), and never
	// seed over legacy files: the launch would run without their secrets.
	if !fileExists(a.paths.HostConfig) && a.getenv("CLAUDE_CONFIG") == "" && !config.FindLegacy(a.paths, a.getenv).Any() {
		if err := writeNewPrivateFile(a.paths.HostConfig, a.flavor.SeedConfig()); err != nil && !errors.Is(err, fs.ErrExist) {
			return err
		}
	}
	if fileExists(a.paths.HostConfig) {
		if err := os.Chmod(a.paths.HostConfig, 0o600); err != nil {
			return err
		}
	}
	for _, directory := range a.flavor.CredDirs() {
		if err := os.MkdirAll(directory, 0o755); err != nil {
			return err
		}
	}
	return nil
}

func legacyFileList(legacy config.LegacyFiles) []string {
	var files []string
	for _, path := range []string{legacy.LauncherConf, legacy.Env, legacy.Mounts} {
		if path != "" {
			files = append(files, path)
		}
	}
	return files
}

func (a *app) warnLegacyIgnored(legacy config.LegacyFiles) {
	fmt.Fprintf(a.stderr, ">> legacy files ignored (config.toml is in use); delete them: %s\n", strings.Join(legacyFileList(legacy), " "))
}

func (a *app) printWarnings(warnings []string) {
	for _, warning := range warnings {
		if !strings.HasPrefix(warning, ">>") {
			warning = ">> " + warning
		}
		fmt.Fprintln(a.stderr, warning)
	}
}

// loadConfigIfPresent returns an empty config when config.toml doesn't exist.
func (a *app) loadConfigIfPresent() (config.Config, error) {
	if !fileExists(a.paths.HostConfig) {
		return config.Config{}, nil
	}
	cfg, warnings, err := config.Load(a.paths.HostConfig)
	a.printWarnings(warnings)
	return cfg, err
}

// loadLaunchConfig applies the legacy-migration rules for commands that
// start a container. It returns a non-zero exit code when the launch must stop.
func (a *app) loadLaunchConfig() (config.Config, int) {
	legacy := config.FindLegacy(a.paths, a.getenv)
	if !fileExists(a.paths.HostConfig) {
		if legacy.Any() {
			fmt.Fprintf(a.stderr, "!! legacy config found and no %s:\n", a.paths.HostConfig)
			for _, file := range legacyFileList(legacy) {
				fmt.Fprintf(a.stderr, "     %s\n", file)
			}
			fmt.Fprintf(a.stderr, "   run 'claude-%s update' to migrate it to config.toml\n", a.paths.Flavor)
			return config.Config{}, 2
		}
		fmt.Fprintf(a.stderr, "!! CLAUDE_CONFIG=%s: no such file\n", a.paths.HostConfig)
		return config.Config{}, 1
	}
	if legacy.Any() {
		a.warnLegacyIgnored(legacy)
	}
	cfg, err := a.loadConfigIfPresent()
	if err != nil {
		fmt.Fprintf(a.stderr, "!! %v\n", err)
		return config.Config{}, 1
	}
	return cfg, 0
}

// githubToken comes from the host keyring via gh; it rides the env file,
// never argv, where ps could read it.
func githubToken() string {
	if _, err := exec.LookPath("gh"); err != nil {
		return ""
	}
	output, err := exec.Command("gh", "auth", "token").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(output))
}

func (a *app) runInContainer(command []string, reseed bool) int {
	cfg, code := a.loadLaunchConfig()
	if code != 0 {
		return code
	}
	containerRuntime, ok := a.requireRuntime()
	if !ok {
		return 1
	}
	extraEnvironment := map[string]string{}
	if token := githubToken(); token != "" {
		extraEnvironment["GH_TOKEN"] = token
	}
	stage, warnings, err := launch.NewStage(a.paths, cfg, extraEnvironment, a.home, a.workingDirectory)
	a.printWarnings(warnings)
	if err != nil {
		fmt.Fprintf(a.stderr, "!! %v\n", err)
		return 1
	}
	defer stage.Remove()

	args, warnings := launch.BuildArgs(launch.RunOptions{
		Paths:            a.paths,
		Config:           cfg,
		Runtime:          containerRuntime,
		Flavor:           a.flavor,
		Stage:            stage,
		Image:            a.image(cfg),
		Getenv:           a.getenv,
		Host:             a.host,
		UID:              os.Getuid(),
		GID:              os.Getgid(),
		TTY:              isTerminal(os.Stdin) && isTerminal(os.Stdout),
		Reseed:           reseed || a.getenv("CLAUDE_RESEED") != "",
		Command:          command,
		WorkingDirectory: a.workingDirectory,
		Home:             a.home,
	})
	a.printWarnings(warnings)
	return launch.Run(args)
}
