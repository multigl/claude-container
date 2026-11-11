package app

import (
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/multigl/claude-container/internal/buildinfo"
	"github.com/multigl/claude-container/internal/config"
	"github.com/multigl/claude-container/internal/runtime"
)

// doctor reports problems rather than failing on them, so it always exits 0.
func (a *app) doctor() int {
	flavorName := a.paths.Flavor
	report := func(format string, arguments ...any) { fmt.Fprintf(a.stdout, format+"\n", arguments...) }

	report("== runtime ==")
	runtimeName := a.resolveRuntime()
	report("  resolved: %s", runtimeName)
	for _, name := range []string{"apple", "docker", "podman"} {
		if runtime.Available(name, a.host) {
			report("  available: %s", name)
		}
	}

	cfg, configError := a.loadConfigIfPresent()
	image := a.image(cfg)
	report("== image (%s) ==", flavorName)
	hint := "run 'just build' (FLAVOR=" + flavorName + "), or drop the image override"
	if image == buildinfo.PinnedImage(flavorName) {
		hint = "run 'claude-" + flavorName + " update'"
	}
	if runtimeName == "none" {
		report("  SKIP: no runtime")
	} else if containerRuntime, err := runtime.New(runtimeName); err == nil && exec.Command(containerRuntime.Binary(), "image", "inspect", image).Run() == nil {
		report("  ok: %s present", image)
	} else {
		report("  MISSING: %s -- %s", image, hint)
	}

	report("== auth (%s) ==", flavorName)
	if configError != nil {
		cfg = config.Config{}
	}
	for _, line := range a.flavor.Doctor(cfg) {
		report("%s", line)
	}

	report("== legacy config ==")
	legacy := config.FindLegacy(a.paths, a.getenv)
	switch {
	case configError != nil:
		report("  ERROR: %v", configError)
	case !fileExists(a.paths.HostConfig) && legacy.Any():
		report("  WARN: legacy files and no %s: %s", a.paths.HostConfig, strings.Join(legacyFileList(legacy), " "))
		report("        run 'claude-%s update' to migrate them", flavorName)
	case !fileExists(a.paths.HostConfig):
		report("  MISSING: %s", a.paths.HostConfig)
	case legacy.Any():
		report("  WARN: legacy files ignored (config.toml is in use); delete them: %s", strings.Join(legacyFileList(legacy), " "))
	default:
		report("  ok: %s", a.paths.HostConfig)
	}

	report("== wrapper on PATH ==")
	if wrapper, err := exec.LookPath("claude-" + flavorName); err == nil {
		report("  ok: %s", wrapper)
	} else {
		report("  MISSING: claude-%s not on PATH; re-run install.sh (or add ~/.local/bin to PATH)", flavorName)
	}

	report("== memory (%s) ==", flavorName)
	report("  global tier: %s", filepath.Join(a.paths.StateClaudeDir, "memory-global"))
	legacyBucket := filepath.Join(a.paths.StateClaudeDir, "projects", "-workspace")
	if directoryHasEntries(legacyBucket) {
		report("  WARN: legacy shared bucket present (%s)", legacyBucket)
		report("        run 'claude-%s migrate-memory' from the owning repo", flavorName)
	} else {
		report("  ok: no legacy shared bucket")
	}
	return 0
}
