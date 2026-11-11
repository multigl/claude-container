package app

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/multigl/claude-container/internal/buildinfo"
	"github.com/multigl/claude-container/internal/config"
)

func directoryHasEntries(path string) bool {
	entries, err := os.ReadDir(path)
	return err == nil && len(entries) > 0
}

// migrateMemory moves the pre-isolation shared bucket to this repo's key.
// The runtime recreates the legacy path as an empty mountpoint stub on every
// run, so only a non-empty one counts as legacy data.
func (a *app) migrateMemory() int {
	legacyBucket := filepath.Join(a.paths.StateClaudeDir, "projects", "-workspace")
	if !directoryHasEntries(legacyBucket) {
		os.Remove(legacyBucket)
		fmt.Fprintf(a.stdout, ">> no legacy bucket at %s; nothing to migrate\n", legacyBucket)
		return 0
	}
	if directoryHasEntries(a.paths.HostProjectDir) {
		fmt.Fprintf(a.stderr, ">> target exists and is non-empty: %s; refusing to overwrite\n", a.paths.HostProjectDir)
		return 1
	}
	// Init pre-created an empty target; drop it so the rename doesn't nest.
	os.Remove(a.paths.HostProjectDir)
	if err := os.MkdirAll(filepath.Dir(a.paths.HostProjectDir), 0o755); err != nil {
		fmt.Fprintf(a.stderr, "!! %v\n", err)
		return 1
	}
	if err := os.Rename(legacyBucket, a.paths.HostProjectDir); err != nil {
		fmt.Fprintf(a.stderr, "!! %v\n", err)
		return 1
	}
	fmt.Fprintf(a.stdout, ">> migrated %s -> %s\n", legacyBucket, a.paths.HostProjectDir)
	return 0
}

// resetAuth reports a removal failure loudly: its whole job is guaranteeing
// the credential is gone.
func (a *app) resetAuth() int {
	code := 0
	for _, path := range a.flavor.CredPaths() {
		if _, err := os.Lstat(path); err != nil {
			continue
		}
		if err := os.RemoveAll(path); err != nil {
			fmt.Fprintf(a.stderr, ">> failed to remove %s\n", path)
			code = 1
			continue
		}
		fmt.Fprintf(a.stdout, ">> wiped %s\n", path)
	}
	return code
}

// migrateCreds copies an old named cred volume into the bind dir. Apple
// `container` never used named volumes.
func (a *app) migrateCreds() int {
	volume := a.flavor.LegacyVolume()
	credDirs := a.flavor.CredDirs()
	if volume == "" || len(credDirs) == 0 {
		fmt.Fprintf(a.stdout, ">> migrate-creds: not applicable for the '%s' flavor\n", a.paths.Flavor)
		return 0
	}
	target := credDirs[0]
	if err := os.MkdirAll(target, 0o755); err != nil {
		fmt.Fprintf(a.stderr, "!! %v\n", err)
		return 1
	}
	if directoryHasEntries(target) {
		fmt.Fprintf(a.stdout, ">> %s already populated; nothing to migrate\n", target)
		return 0
	}
	binary := a.resolveRuntime()
	if binary != "docker" && binary != "podman" {
		fmt.Fprintf(a.stdout, ">> migrate-creds needs docker or podman (got: %s)\n", binary)
		return 1
	}
	if exec.Command(binary, "volume", "inspect", volume).Run() != nil {
		fmt.Fprintf(a.stdout, ">> no volume %s; nothing to migrate\n", volume)
		return 0
	}
	copyCommand := exec.Command(binary, "run", "--rm", "-v", volume+":/from:ro", "-v", target+":/to", "alpine",
		"sh", "-c", "cp -a /from/. /to/ 2>/dev/null || true")
	copyCommand.Stdout = a.stdout
	copyCommand.Stderr = a.stderr
	if err := copyCommand.Run(); err != nil {
		fmt.Fprintf(a.stderr, "!! %v\n", err)
		return 1
	}
	fmt.Fprintf(a.stdout, ">> migrated volume %s -> %s\n", volume, target)
	return 0
}

// update runs its steps in order and stops at the first failure.
func (a *app) update() int {
	for _, step := range []func() int{a.migrateLegacyConfig, a.pullPinnedImage} {
		if code := step(); code != 0 {
			return code
		}
	}
	return 0
}

// migrateLegacyConfig writes config.toml from the legacy files, only when
// config.toml doesn't exist yet. The originals stay for the user to check.
func (a *app) migrateLegacyConfig() int {
	legacy := config.FindLegacy(a.paths, a.getenv)
	if !legacy.Any() {
		return 0
	}
	if fileExists(a.paths.HostConfig) {
		a.warnLegacyIgnored(legacy)
		return 0
	}
	tomlText, report, err := config.Migrate(legacy)
	if err != nil {
		fmt.Fprintf(a.stderr, "!! migrating legacy config: %v\n", err)
		return 1
	}
	if err := writeNewPrivateFile(a.paths.HostConfig, tomlText); err != nil {
		fmt.Fprintf(a.stderr, "!! writing %s: %v\n", a.paths.HostConfig, err)
		return 1
	}
	for _, file := range legacyFileList(legacy) {
		fmt.Fprintf(a.stdout, ">> migrated %s -> %s\n", file, a.paths.HostConfig)
	}
	for _, line := range report {
		fmt.Fprintf(a.stdout, ">> %s\n", line)
	}
	fmt.Fprintln(a.stdout, ">> delete the old files once you've checked config.toml")
	return 0
}

// pullPinnedImage always pulls the image this build is pinned to; an
// override is only called out, never pulled or replaced.
func (a *app) pullPinnedImage() int {
	cfg, err := a.loadConfigIfPresent()
	if err != nil {
		fmt.Fprintf(a.stderr, "!! %v\n", err)
		return 1
	}
	containerRuntime, ok := a.requireRuntime()
	if !ok {
		return 1
	}
	pinned := buildinfo.PinnedImage(a.paths.Flavor)
	fmt.Fprintf(a.stdout, ">> pulling %s via %s\n", pinned, containerRuntime.Name())
	if err := containerRuntime.Pull(pinned); err != nil {
		fmt.Fprintf(a.stderr, "!! pull failed for %s (offline, or the GHCR package is still private?)\n", pinned)
		return 1
	}
	if version := containerRuntime.ImageLabel(pinned, "org.opencontainers.image.version"); version != "" {
		fmt.Fprintf(a.stdout, ">> claude-code %s\n", version)
	}
	if image := a.image(cfg); image != pinned {
		fmt.Fprintf(a.stderr, ">> note: image override active (%s); plain claude-%s keeps running it, not %s\n", image, a.paths.Flavor, pinned)
	}
	return 0
}
