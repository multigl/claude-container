package launch

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/multigl/claude-container/internal/config"
	"github.com/multigl/claude-container/internal/paths"
)

const stagePrefix = ".stage."

// Older than a day spares the fresh stage of a concurrently running launch.
const staleStageAge = 24 * time.Hour

// Stage is the per-run snapshot of host files mounted once at
// /opt/claude-stage; single-file bind mounts go stale on Docker Desktop macOS.
// EnvFile sits beside Dir, not in it, so the mounted dir never carries env secrets.
type Stage struct {
	Dir     string
	EnvFile string
}

// sweepStaleStages removes stage dirs and env files stranded by a crashed
// launch, whose own cleanup never ran.
func sweepStaleStages(stateDir string) {
	entries, err := os.ReadDir(stateDir)
	if err != nil {
		return
	}
	cutoff := time.Now().Add(-staleStageAge)
	for _, entry := range entries {
		if !strings.HasPrefix(entry.Name(), stagePrefix) {
			continue
		}
		info, err := entry.Info()
		if err != nil || !info.ModTime().Before(cutoff) {
			continue
		}
		os.RemoveAll(filepath.Join(stateDir, entry.Name()))
	}
}

// copyIfPresent copies source to destination; a missing source is not an error.
func copyIfPresent(source, destination string) error {
	content, err := os.ReadFile(source)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	return os.WriteFile(destination, content, 0o600)
}

func NewStage(p paths.Paths, cfg config.Config, home, workingDirectory string) (Stage, []string, error) {
	sweepStaleStages(p.StateDir)
	directory, err := os.MkdirTemp(p.StateDir, stagePrefix)
	if err != nil {
		return Stage{}, nil, err
	}
	stage := Stage{Dir: directory, EnvFile: directory + ".env"}

	// Staged file name -> host source; names are what the entrypoint reads.
	hostSources := map[string]string{
		"settings.override.json": p.HostSettings,
		"host-claude.json":       filepath.Join(home, ".claude.json"),
		"statusline.sh":          filepath.Join(home, ".claude", "statusline-command.sh"),
	}
	for stagedName, source := range hostSources {
		if err := copyIfPresent(source, filepath.Join(directory, stagedName)); err != nil {
			stage.Remove()
			return Stage{}, nil, err
		}
	}

	identity, warnings := GitIdentity(workingDirectory)
	if err := os.WriteFile(filepath.Join(directory, "gitconfig-identity"), []byte(identity), 0o600); err != nil {
		stage.Remove()
		return Stage{}, nil, err
	}
	if err := config.WriteEnvFile(stage.EnvFile, cfg.Env); err != nil {
		stage.Remove()
		return Stage{}, nil, err
	}
	return stage, warnings, nil
}

func (s Stage) Remove() {
	os.RemoveAll(s.Dir)
	os.Remove(s.EnvFile)
}
